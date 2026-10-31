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

    struct LedgerEntry { uint64_t screen_off = 0, screen_on = 0, top_app = 0; int64_t last_ms = 0; };

    AsbObserverResult start(const AsbObserverFrame &frame, int64_t now_ms) {
        if (!asb_observer_frame_valid(frame) || frame.kind != ASB_OBSERVER_EVENT_PROCESS_START) {
            ++invalid_; ++dropped_; return AsbObserverResult::invalid;
        }
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

    /* fix272: a new top-app process is a cold start. Its own budget, separate from the
     * refresh hints: one per second at most and 20 per minute, shared by both ABIs. */
    bool launch_permit(int64_t now_ms) {
        if (now_ms <= 0) return false;
        if (last_launch_ms_ >= 0 && now_ms < last_launch_ms_) {
            launch_history_.clear();
            last_launch_ms_ = -1;
        }
        if (last_launch_ms_ >= 0 && now_ms - last_launch_ms_ < ASB_OBSERVER_LAUNCH_MIN_INTERVAL_MS)
            return false;
        while (!launch_history_.empty() && now_ms - launch_history_.front() >= 60000)
            launch_history_.pop_front();
        if (launch_history_.size() >= ASB_OBSERVER_LAUNCH_MAX_PER_MINUTE) return false;
        launch_history_.push_back(now_ms);
        last_launch_ms_ = now_ms;
        return true;
    }

    /* fix272: process starts per package for this boot, split by the screen state the
     * governor last published. Bounded: a full table drops the entry seen least and longest
     * ago, so a burst of one-off packages cannot grow it. */
    void ledger_record(const std::string &package, int screen_on, bool top_app, int64_t now_ms) {
        auto it = ledger_.find(package);
        if (it == ledger_.end()) {
            if (ledger_.size() >= ASB_OBSERVER_LEDGER_MAX) {
                auto victim = ledger_.begin();
                for (auto c = ledger_.begin(); c != ledger_.end(); ++c) {
                    const uint64_t a = c->second.screen_off + c->second.screen_on;
                    const uint64_t b = victim->second.screen_off + victim->second.screen_on;
                    if (a < b || (a == b && c->second.last_ms < victim->second.last_ms)) victim = c;
                }
                ledger_.erase(victim);
                ++ledger_evicted_;
            }
            it = ledger_.emplace(package, LedgerEntry()).first;
        }
        if (screen_on == 0) ++it->second.screen_off; else ++it->second.screen_on;
        if (top_app) ++it->second.top_app;
        it->second.last_ms = now_ms;
        ++ledger_events_;
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
    const std::map<std::string, LedgerEntry> &ledger() const { return ledger_; }
    uint64_t ledger_events() const { return ledger_events_; }
    uint64_t ledger_evicted() const { return ledger_evicted_; }

private:
    std::map<int, Process> processes_;
    std::map<std::string, std::deque<int64_t>> history_;
    std::deque<int64_t> hint_history_;
    int64_t last_hint_ms_ = -1;
    std::deque<int64_t> launch_history_;
    int64_t last_launch_ms_ = -1;
    std::map<std::string, LedgerEntry> ledger_;
    uint64_t ledger_events_ = 0, ledger_evicted_ = 0;
    uint64_t events_total_ = 0, dropped_ = 0, rate_limited_ = 0;
    uint64_t duplicate_ = 0, invalid_ = 0, capacity_dropped_ = 0;
};

#endif
