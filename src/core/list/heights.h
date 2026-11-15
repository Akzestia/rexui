// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstdint>
#include <vector>

namespace rx::list {

class Heights {
  public:
    void set_gap(double gap) noexcept { gap_ = gap; }
    void set_fixed(double h) noexcept { fixed_ = h; }
    bool fixed() const noexcept { return fixed_ > 0; }
    uint32_t count() const noexcept { return n_; }

    void resize(uint32_t n) {
        if (n < n_) {
            const uint32_t from = o_ + n, size = static_cast<uint32_t>(h_.size());
            for (uint32_t a = from; a < size; a++)
                if (h_[a] >= 0)
                    known_sum_ -= h_[a], known_n_--;
            if (size > from)
                h_.resize(from), sum_.resize(from + 1), cnt_.resize(from + 1);
        }
        n_ = n;
    }

    void shift(int64_t d) {
        if (!d)
            return;
        if (d < 0)
            return prepend(static_cast<uint32_t>(-d));
        if (static_cast<uint64_t>(d) >= n_)
            return clear();
        const uint32_t k = static_cast<uint32_t>(d);
        double s = 0;
        uint32_t c = 0;
        prefix(o_ + k, s, c);
        double s0 = 0;
        uint32_t c0 = 0;
        prefix(o_, s0, c0);
        known_sum_ -= s - s0, known_n_ -= c - c0;
        o_ += k, n_ -= k;
        if (o_ >= 4096 && o_ > h_.size() / 2)
            compact();
    }

    void measure(uint32_t i, double height) {
        if (i >= n_ || fixed())
            return;
        const uint32_t a = o_ + i;
        grow(a + 1);
        const float h = static_cast<float>(height);
        const float was = h_[a];
        if (was == h)
            return;
        const bool fresh = was < 0;
        const double d = fresh ? h : static_cast<double>(h) - was;
        h_[a] = h;
        known_sum_ += d;
        if (fresh)
            known_n_++;
        for (uint32_t k = a + 1; k <= static_cast<uint32_t>(h_.size()); k += k & (~k + 1)) {
            sum_[k] += d;
            if (fresh)
                cnt_[k]++;
        }
    }

    double mean() const noexcept { return known_n_ ? known_sum_ / known_n_ : guess_; }
    void set_guess(double h) noexcept { guess_ = h; }

    double height(uint32_t i) const noexcept {
        if (fixed())
            return fixed_;
        const uint32_t a = o_ + i;
        return a < h_.size() && h_[a] >= 0 ? h_[a] : mean();
    }

    double y(uint32_t i) const noexcept {
        if (fixed())
            return i * (fixed_ + gap_);
        const double m = mean();
        return w(o_ + i, m) - w(o_, m);
    }

    double total() const noexcept { return n_ ? y(n_) - gap_ : 0; }

    uint32_t at(double y) const noexcept {
        if (!n_ || y <= 0)
            return 0;
        if (fixed()) {
            const double step = fixed_ + gap_;
            const double r = step > 0 ? y / step : 0;
            return r >= n_ ? n_ - 1 : static_cast<uint32_t>(r);
        }
        const double m = mean();
        const double target = y + w(o_, m);
        const uint32_t sized = static_cast<uint32_t>(h_.size());
        uint32_t pos = 0;
        double acc = 0;
        uint32_t bit = 1;
        while (bit <= sized / 2)
            bit <<= 1;
        for (; sized && bit; bit >>= 1) {
            const uint32_t next = pos + bit;
            if (next > sized)
                continue;
            const double wb = sum_[next] + (bit - cnt_[next]) * m + bit * gap_;
            if (acc + wb <= target)
                pos = next, acc += wb;
        }
        const uint32_t end = o_ + n_;
        if (pos >= sized && pos < end) {
            const double step = m + gap_;
            if (step > 0) {
                const double more = (target - acc) / step;
                pos += static_cast<uint32_t>(more < end - pos ? more : end - pos);
            }
        }
        if (pos < o_)
            return 0;
        const uint32_t i = pos - o_;
        return i >= n_ ? n_ - 1 : i;
    }

  private:
    void grow(uint32_t size) {
        uint32_t have = static_cast<uint32_t>(h_.size());
        if (size <= have)
            return;
        h_.resize(size, -1);
        sum_.resize(size + 1, 0);
        cnt_.resize(size + 1, 0);
        for (uint32_t k = have + 1; k <= size; k++) {
            const uint32_t low = k & (~k + 1);
            for (uint32_t j = 1; j < low; j <<= 1)
                sum_[k] += sum_[k - j], cnt_[k] += cnt_[k - j];
        }
    }

    void prefix(uint32_t a, double& s, uint32_t& c) const noexcept {
        const uint32_t sized = static_cast<uint32_t>(h_.size());
        for (uint32_t k = a < sized ? a : sized; k; k &= k - 1)
            s += sum_[k], c += cnt_[k];
    }
    double w(uint32_t a, double m) const noexcept {
        double s = 0;
        uint32_t c = 0;
        prefix(a, s, c);
        return s + (a - c) * m + a * gap_;
    }

    void rebuild(std::vector<float>&& live) {
        h_.clear(), sum_.clear(), cnt_.clear();
        o_ = 0;
        known_sum_ = 0, known_n_ = 0;
        grow(static_cast<uint32_t>(live.size()));
        for (uint32_t a = 0; a < live.size(); a++)
            if (live[a] >= 0) {
                h_[a] = live[a];
                known_sum_ += live[a], known_n_++;
                for (uint32_t k = a + 1; k <= static_cast<uint32_t>(h_.size()); k += k & (~k + 1))
                    sum_[k] += live[a], cnt_[k]++;
            }
    }
    void compact() {
        const uint32_t size = static_cast<uint32_t>(h_.size());
        std::vector<float> live(h_.begin() + (o_ < size ? o_ : size), h_.end());
        rebuild(std::move(live));
    }
    void prepend(uint32_t k) {
        const uint32_t size = static_cast<uint32_t>(h_.size());
        std::vector<float> live(k, -1.f);
        if (o_ < size)
            live.insert(live.end(), h_.begin() + o_, h_.end());
        const uint32_t n = n_ + k;
        rebuild(std::move(live));
        n_ = n;
    }
    void clear() {
        h_.clear(), sum_.clear(), cnt_.clear();
        o_ = 0, n_ = 0;
        known_sum_ = 0, known_n_ = 0;
    }

    uint32_t n_ = 0;
    uint32_t o_ = 0;
    double gap_ = 0, fixed_ = 0, guess_ = 24;
    double known_sum_ = 0;
    uint32_t known_n_ = 0;
    std::vector<float> h_;
    std::vector<double> sum_;
    std::vector<uint32_t> cnt_;
};

}
