#ifndef ASB_OBSERVER_CORE_H
#define ASB_OBSERVER_CORE_H

#include "asb_observer_protocol.h"
#include <deque>
#include <map>

/* Bounded, event-driven aggregation. There is deliberately no timer or poll loop. */
enum class AsbObserverResult { accepted, duplicate, rate_limited, capacity, invalid };

class AsbObserverCore {
public:
    struct Process { std::string package; uint64_t start_ticks; int64_t started_ms; };

    AsbObserverResult start(const AsbObserverFrame &frame, int64_t now_ms) {
        if (!asb_observer_frame_valid(frame)) { ++invalid_; ++dropped_; return AsbObserverResult::invalid; }
        if (processes_.count(frame.pid)) { ++duplicate_; ++dropped_; return AsbObserverResult::duplicate; }
        auto &history = history_[frame.package];
        while (!history.empty() && now_ms - history.front() >= 60000) history.pop_front();
        if ((!history.empty() && now_ms - history.back() < 1000) ||
            history.size() >= ASB_OBSERVER_MAX_EVENTS_PER_MINUTE) {
            ++rate_limited_; ++dropped_; return AsbObserverResult::rate_limited;
        }
        if (processes_.size() >= ASB_OBSERVER_MAX_PROCESSES) {
            ++capacity_dropped_; ++dropped_; return AsbObserverResult::capacity;
        }
        history.push_back(now_ms);
        processes_[frame.pid] = {frame.package, frame.process_start_ticks, frame.monotonic_ms};
        ++events_total_;
        return AsbObserverResult::accepted;
    }

    void reject_invalid() { ++invalid_; ++dropped_; }

    bool exit(int pid) {
        auto it = processes_.find(pid);
        if (it == processes_.end()) return false;
        processes_.erase(it);
        ++events_total_;
        return true;
    }

    /* A lifecycle hint is a request for fresh governor evidence, never a policy decision.
     * One global budget covers concurrent companion handlers and both ABIs in a process.
     * The screen-on check and final veto remain with the governor. */
    bool hint_permit(int64_t now_ms) {
        if (now_ms <= 0) return false;
        if (last_hint_ms_ >= 0 && now_ms < last_hint_ms_) {
            hint_history_.clear();
            last_hint_ms_ = -1;
        }
        if (last_hint_ms_ >= 0 && now_ms - last_hint_ms_ < ASB_OBSERVER_HINT_MIN_INTERVAL_MS)
            return false;
        while (!hint_history_.empty() && now_ms - hint_history_.front() >= 60000)
            hint_history_.pop_front();
        if (hint_history_.size() >= ASB_OBSERVER_HINT_MAX_PER_MINUTE) return false;
        hint_history_.push_back(now_ms);
        last_hint_ms_ = now_ms;
        return true;
    }

    /* TTL applies to rate-window history, never to a live process with no events. */
    void prune(int64_t now_ms) {
        for (auto it = history_.begin(); it != history_.end();) {
            auto &q = it->second;
            while (!q.empty() && now_ms - q.front() >= 60000) q.pop_front();
            if (q.empty()) it = history_.erase(it); else ++it;
        }
    }

    size_t loaded() const { return processes_.size(); }
    uint64_t events_total() const { return events_total_; }
    uint64_t dropped() const { return dropped_; }
    uint64_t rate_limited() const { return rate_limited_; }
    uint64_t duplicate() const { return duplicate_; }
    uint64_t invalid() const { return invalid_; }
    uint64_t capacity_dropped() const { return capacity_dropped_; }
    const std::map<int, Process> &processes() const { return processes_; }

private:
    std::map<int, Process> processes_;
    std::map<std::string, std::deque<int64_t>> history_;
    std::deque<int64_t> hint_history_;
    int64_t last_hint_ms_ = -1;
    uint64_t events_total_ = 0, dropped_ = 0, rate_limited_ = 0;
    uint64_t duplicate_ = 0, invalid_ = 0, capacity_dropped_ = 0;
};

#endif
