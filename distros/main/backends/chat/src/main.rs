// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: GPL-3.0-only
mod rexui;

use std::collections::BTreeMap;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Context;
use moq_net::Path;
use moq_room::{Kind, Room, chat};
use serde_json::json;
use tokio::sync::mpsc;

enum Input {
	Send(String),
	Closed,
}

enum Remote {
	Joined(String),
	Left(String),
	Message(String, String),
}

fn now_ms() -> u64 {
	SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

const SIGTERM: i32 = 15;
const SIG_IGN: usize = 1;
unsafe extern "C" {
	fn signal(signum: i32, handler: usize) -> usize;
}

fn out(mut v: serde_json::Value) {
	if let Some(st) = v.as_object_mut().and_then(|o| o.remove("state")) {
		rexui::state_json(&st.to_string());
	}
	if v.as_object().is_some_and(|o| !o.is_empty()) {
		rexui::message(&v.to_string());
	}
}

const RELAY: &str = "cdn.moq.pro";

fn relay_url(typed: &str, token: &str) -> anyhow::Result<url::Url> {
	let typed = typed.trim();
	let first = typed.split(['/', '?']).next().unwrap_or("");
	let host = typed.contains("://")
		|| (!typed.starts_with('/') && (first.contains('.') || first.contains(':') || first == "localhost"));
	let local = ["localhost", "127.0.0.1", "[::1]"].iter().any(|h| typed.starts_with(h));
	let full = if typed.contains("://") {
		typed.to_string()
	} else if host {
		format!("{}://{typed}", if local { "http" } else { "https" })
	} else {
		let path = typed.trim_start_matches('/');
		anyhow::ensure!(!path.is_empty() && !path.starts_with('?'), "no room");
		format!("https://{RELAY}/{path}")
	};
	let mut url = url::Url::parse(&full).context("not a relay URL")?;
	if !token.is_empty() {
		let kept: Vec<(String, String)> = url.query_pairs().filter(|(k, _)| k != "jwt").map(|(k, v)| (k.into(), v.into())).collect();
		url.query_pairs_mut().clear().extend_pairs(kept).append_pair("jwt", token);
	}
	Ok(url)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
	unsafe {
		signal(SIGTERM, SIG_IGN);
	}
	rexui::begin();
	let mut args = std::env::args().skip(1);
	let typed = args.next().unwrap_or_default();
	let name = args
		.next()
		.filter(|n| !n.is_empty())
		.or_else(|| std::env::var("USER").ok())
		.unwrap_or_else(|| "rex".into());
	let name: String = name.chars().filter(|c| c.is_alphanumeric() || *c == '-' || *c == '_').collect();
	let token = args.next().unwrap_or_default();
	let quiet = |e: &dyn std::fmt::Display| {
		let t = format!("{e:#}");
		if token.is_empty() { t } else { t.replace(&token, "<token>") }
	};
	let url = match relay_url(&typed, &token) {
		Ok(u) if !typed.trim().is_empty() => u,
		res => {
			let why = res.err().map(|e| quiet(&e)).unwrap_or_else(|| "no relay URL".into());
			out(json!({"state": {"status": "disconnected", "error": why, "relay": "", "room": "", "name": name, "peers": []}}));
			eprintln!("rexui-chat: {why}");
			std::process::exit(2);
		}
	};
	let room = url.path().trim_matches('/').to_string();
	let relay = match (url.host_str(), url.port()) {
		(Some(h), Some(p)) => format!("{h}:{p}"),
		(Some(h), None) => h.to_string(),
		_ => String::new(),
	};

	let mut peers: BTreeMap<String, ()> = BTreeMap::new();
	let state = |status: &str, peers: &BTreeMap<String, ()>| {
		out(json!({"state": {"status": status, "relay": relay, "room": room, "name": name,
		                     "peers": peers.keys().collect::<Vec<_>>()}}));
	};
	state("connecting", &peers);

	let origin = moq_tokio::origin::spawn();
	let mut broadcast = origin
		.create_broadcast(moq_room::broadcast_path(Path::new(&name), Kind::Camera))
		.context("cannot create our broadcast")?;
	let mut publisher = chat::Publisher::create(&mut broadcast)?;
	broadcast.announce(Default::default())?;

	let client = moq_tokio::connect::Config::default().init(Default::default())?.with_origin(origin.clone());
	let mut connection = client.connect(url);

	let (input_tx, mut input) = mpsc::channel::<Input>(64);
	tokio::task::spawn_blocking(move || {
		while let rexui::Next::Message(line) = rexui::next(None) {
			let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) else { continue };
			if let Some(text) = v.get("send").and_then(|t| t.as_str()) {
				if input_tx.blocking_send(Input::Send(text.to_string())).is_err() {
					return;
				}
			}
		}
		let _ = input_tx.blocking_send(Input::Closed);
	});

	let (remote_tx, mut remote) = mpsc::channel::<Remote>(256);
	let mut members = Room::new(&origin.consume(), Some(Path::new(&name).to_owned()));
	tokio::spawn(async move {
		while let Some(event) = members.next().await {
			if event.kind != Kind::Camera {
				continue;
			}
			let who = event.identity.to_string();
			let Some(b) = event.broadcast else {
				let _ = remote_tx.send(Remote::Left(who)).await;
				continue;
			};
			let _ = remote_tx.send(Remote::Joined(who.clone())).await;
			let tx = remote_tx.clone();
			tokio::spawn(async move {
				let Ok(mut sub) = chat::Subscriber::subscribe(&b).await else { return };
				while let Ok(Some(ev)) = sub.recv().await {
					if let chat::Event::Push { value, .. } = ev {
						if tx.send(Remote::Message(who.clone(), value)).await.is_err() {
							return;
						}
					}
				}
			});
		}
	});

	let mut settled = false;
	let mut settle_cap: Option<tokio::time::Instant> = None;
	let settle = tokio::time::sleep(std::time::Duration::from_secs(86400));
	tokio::pin!(settle);
	let quiet_for = std::time::Duration::from_millis(1000);

	loop {
		tokio::select! {
			() = &mut settle, if !settled => { settled = true; }
			status = connection.status() => {
				match status {
					Ok(moq_tokio::Status::Connected) => {
						state("connected", &peers);
						out(json!({"state": {"error": ""}}));
						if !settled {
							let now = tokio::time::Instant::now();
							let cap = *settle_cap.get_or_insert(now + std::time::Duration::from_secs(5));
							settle.as_mut().reset((now + quiet_for).min(cap));
						}
					}
					Ok(moq_tokio::Status::Disconnected) => state("disconnected", &peers),
					Ok(_) => {}
					Err(e) => {
						let why = quiet(&e);
						eprintln!("connection: {why}");
						state("disconnected", &peers);
						out(json!({"state": {"error": why}}));
						std::process::exit(1);
					}
				}
			}
			Some(msg) = input.recv() => match msg {
				Input::Send(text) => {
					let text = text.trim();
					if text.is_empty() { continue; }
					if let Err(e) = publisher.send(text) { eprintln!("send: {e}"); continue; }
					out(json!({"message": {"from": name, "text": text, "me": true, "at": now_ms()}}));
				}
				Input::Closed => break,
			},
			Some(r) = remote.recv() => match r {
				Remote::Joined(who) => {
					if peers.insert(who.clone(), ()).is_none() {
						if settled {
							out(json!({"event": "joined", "name": who}));
						} else {
							let now = tokio::time::Instant::now();
							let cap = *settle_cap.get_or_insert(now + std::time::Duration::from_secs(5));
							settle.as_mut().reset((now + quiet_for).min(cap));
						}
						state(if connection.connected() { "connected" } else { "connecting" }, &peers);
					}
				}
				Remote::Left(who) => {
					if peers.remove(&who).is_some() {
						out(json!({"event": "left", "name": who}));
						state(if connection.connected() { "connected" } else { "disconnected" }, &peers);
					}
				}
				Remote::Message(who, text) => out(json!({"message": {"from": who, "text": text, "me": false, "at": now_ms()}})),
			},
			res = publisher.expire() => { if let Err(e) = res { eprintln!("expire: {e}"); } }
		}
	}
	let _ = publisher.finish();
	broadcast.close();
	let _ = tokio::time::timeout(std::time::Duration::from_millis(1500), connection.close()).await;
	Ok(())
}

#[cfg(test)]
mod tests {
	use super::relay_url;

	#[test]
	fn scheme_room_and_token() {
		let u = relay_url("moq.pro/room", "").unwrap();
		assert_eq!(u.as_str(), "https://moq.pro/room");
		assert_eq!(relay_url("rewrite-in-cpp", "").unwrap().as_str(), "https://cdn.moq.pro/rewrite-in-cpp");
		assert_eq!(relay_url("/project/room", "").unwrap().as_str(), "https://cdn.moq.pro/project/room");
		assert_eq!(relay_url(" project/room ", "t").unwrap().as_str(), "https://cdn.moq.pro/project/room?jwt=t");
		assert_eq!(relay_url("cdn.moq.dev/anon/x", "").unwrap().as_str(), "https://cdn.moq.dev/anon/x");
		assert_eq!(relay_url("localhost/anon/x", "").unwrap().as_str(), "http://localhost/anon/x");
		assert_eq!(relay_url("[::1]:4443/anon/x", "").unwrap().scheme(), "http");
		assert!(relay_url("/", "").is_err());
		assert_eq!(relay_url("localhost:4443/anon/x", "").unwrap().scheme(), "http");
		assert_eq!(relay_url("http://example.org/a/b", "").unwrap().path(), "/a/b");
		let t = relay_url("  cdn.example/room?jwt=old&x=1 ", "new.tok-en").unwrap();
		let q: Vec<(String, String)> = t.query_pairs().map(|(k, v)| (k.into(), v.into())).collect();
		assert_eq!(q, vec![("x".into(), "1".into()), ("jwt".into(), "new.tok-en".into())]);
		assert_eq!(relay_url("cdn.example/room?jwt=kept", "").unwrap().query(), Some("jwt=kept"));
		assert!(relay_url("", "").is_err());
	}
}
