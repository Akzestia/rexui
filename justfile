import 'jm/env.just'

mod build 'jm/build.just'
mod app 'jm/app.just'
mod backends 'jm/backends.just'
mod apps 'jm/apps.just'
mod deps 'jm/deps.just'
mod editor 'jm/editor.just'
mod cli 'jm/cli.just'
mod mcp 'jm/mcp.just'

b: build::dylib

r: build::dylib app::relaunch

requirements:
    @bash src/cli/requirements.sh

install: build::release deps::all backends::install apps::install cli::install app::install cli::examples
