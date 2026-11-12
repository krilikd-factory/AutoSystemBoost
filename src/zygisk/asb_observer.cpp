#include "zygisk.hpp"
#include "asb_observer_core.h"

#include <cerrno>
#include <cstdlib>
#include <fcntl.h>
#include <map>
#include <mutex>
#include <vector>
#include <poll.h>
#include <pthread.h>
#include <sstream>
#include <string>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#ifndef ASB_ABI_TAG
#define ASB_ABI_TAG "unknown"
#endif
#ifndef ASB_GOVERNOR_SOCKET
#define ASB_GOVERNOR_SOCKET "/dev/.asb/ctl.sock"
#endif
#ifndef ASB_GOVERNOR_CLIENT_DIR
#define ASB_GOVERNOR_CLIENT_DIR "/dev/.asb"
#endif
#define ASB_GOVERNOR_HINT_TIMEOUT_US 100000
#ifndef __NR_pidfd_open
#define __NR_pidfd_open 434
#endif

namespace {

/* Plain syscalls only: the zygote-side path must not construct iostreams or parse the
 * 40 KB governor.conf on every fork (fix272). */
ssize_t read_small(int fd, char *buf, size_t cap) {
    size_t done = 0;
    while (done < cap) {
        const ssize_t n = read(fd, buf + done, cap - done);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) return -1;
        if (n == 0) break;
        done += static_cast<size_t>(n);
    }
    return static_cast<ssize_t>(done);
}

bool load_policy_fd(int fd, AsbObserverPolicy &policy) {
    char buf[ASB_OBSERVER_POLICY_MAX_BYTES + 1];
    const ssize_t n = read_small(fd, buf, sizeof(buf));
    close(fd);
    if (n <= 0 || static_cast<size_t>(n) > ASB_OBSERVER_POLICY_MAX_BYTES) return false;
    return asb_observer_policy_parse(buf, static_cast<size_t>(n), policy);
}

/* Root side (companion): the same generated policy, read by absolute path. */
bool load_policy_root(AsbObserverPolicy &policy) {
    const int fd = open(ASB_ZYGISK_POLICY_ABS, O_RDONLY | O_CLOEXEC);
    if (fd < 0) { policy = AsbObserverPolicy(); return false; }
    return load_policy_fd(fd, policy);
}

uint64_t process_start_ticks(pid_t pid) {
    char path[48];
    std::snprintf(path, sizeof(path), "/proc/%d/stat", static_cast<int>(pid));
    const int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    char buf[1024];
    const ssize_t n = read_small(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return 0;
    buf[n] = 0;
    char *p = std::strrchr(buf, ')');
    if (!p || p[1] != ' ') return 0;
    p += 2; /* field 3 */
    for (int field = 3; field < 22; ++field) {
        p = std::strchr(p, ' ');
        if (!p) return 0;
        ++p;
    }
    char *end = nullptr;
    errno = 0;
    const unsigned long long value = std::strtoull(p, &end, 10);
    if (end == p || errno != 0) return 0;
    return static_cast<uint64_t>(value);
}

long process_rss_kb(pid_t pid) {
    char path[48];
    std::snprintf(path, sizeof(path), "/proc/%d/status", static_cast<int>(pid));
    const int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    char buf[4096];
    const ssize_t n = read_small(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return 0;
    buf[n] = 0;
    const char *p = std::strstr(buf, "\nVmRSS:");
    if (!p) return 0;
    return std::strtol(p + 7, nullptr, 10);
}

/* The screen state the governor last published: 1 on, 0 off, -1 unknown. */
int governor_screen_on() {
    const int fd = open(ASB_GOVERNOR_STATE, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    char buf[4096];
    const ssize_t n = read_small(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return -1;
    buf[n] = 0;
    const char *p = std::strstr(buf, "\nscreen=");
    if (!p) return -1;
    if (p[8] == '0') return 0;
    if (p[8] == '1') return 1;
    return -1;
}

bool write_all(int fd, const void *data, size_t size) {
    const char *p = static_cast<const char *>(data);
    while (size) {
        const ssize_t n = send(fd, p, size, MSG_NOSIGNAL);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        p += n;
        size -= static_cast<size_t>(n);
    }
    return true;
}

// 1 = complete frame, 0 = orderly disconnect, -1 = malformed/truncated stream.
int read_frame(int fd, AsbObserverFrame &frame) {
    char *p = reinterpret_cast<char *>(&frame);
    size_t done = 0;
    while (done < sizeof(frame)) {
        const ssize_t n = recv(fd, p + done, sizeof(frame) - done, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n == 0) return done == 0 ? 0 : -1;
        if (n < 0) return -1;
        done += static_cast<size_t>(n);
    }
    return 1;
}

/* fix339: a process fd (Linux 5.3+) turns readable when that process exits. It needs no
 * cooperation from the app, so an exit is seen even when the loader would not let the app
 * keep the companion socket. -1 on an older kernel. */
int open_pidfd(int pid) {
    return static_cast<int>(syscall(__NR_pidfd_open, pid, 0));
}

AsbObserverFrame make_frame(uint16_t kind, uint32_t flags, const std::string &package) {
    AsbObserverFrame frame {};
    frame.magic = ASB_OBSERVER_MAGIC;
    frame.version = ASB_OBSERVER_VERSION;
    frame.kind = kind;
    frame.size = sizeof(frame);
    frame.pid = getpid();
    frame.flags = flags;
    frame.process_start_ticks = process_start_ticks(frame.pid);
    frame.monotonic_ms = asb_observer_monotonic_ms();
    if (package.size() < sizeof(frame.package))
        std::snprintf(frame.package, sizeof(frame.package), "%s", package.c_str());
    return frame;
}

enum class GovernorHintResult { accepted, vetoed, unavailable };

/* One bounded datagram round trip with a fixed opcode. No package name or tuning value
 * crosses this interface. An old/missing governor simply leaves its current policy
 * untouched; the application is never punished for a timeout. */
GovernorHintResult request_governor(const char *command) {
    int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return GovernorHintResult::unavailable;
    struct sockaddr_un client_addr {};
    client_addr.sun_family = AF_UNIX;
    std::snprintf(client_addr.sun_path, sizeof(client_addr.sun_path),
                  "%s/zygisk_hint_%d.sock", ASB_GOVERNOR_CLIENT_DIR, static_cast<int>(getpid()));
    unlink(client_addr.sun_path);
    if (bind(fd, reinterpret_cast<struct sockaddr *>(&client_addr), sizeof(client_addr)) != 0) {
        close(fd);
        return GovernorHintResult::unavailable;
    }
    struct timeval timeout {0, ASB_GOVERNOR_HINT_TIMEOUT_US};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    struct sockaddr_un server_addr {};
    server_addr.sun_family = AF_UNIX;
    std::snprintf(server_addr.sun_path, sizeof(server_addr.sun_path), "%s", ASB_GOVERNOR_SOCKET);
    const size_t length = std::strlen(command);
    const ssize_t sent = sendto(fd, command, length, 0,
                                reinterpret_cast<struct sockaddr *>(&server_addr), sizeof(server_addr));
    GovernorHintResult result = GovernorHintResult::unavailable;
    if (sent == static_cast<ssize_t>(length)) {
        char reply[32] {};
        const ssize_t got = recv(fd, reply, sizeof(reply) - 1, 0);
        if (got > 0) result = std::strcmp(reply, "ok") == 0
            ? GovernorHintResult::accepted : GovernorHintResult::vetoed;
    }
    unlink(client_addr.sun_path);
    close(fd);
    return result;
}

GovernorHintResult request_governor_refresh() {
    static const char command[] = "zygisk-refresh";
    return request_governor(command);
}

GovernorHintResult request_governor_launch() {
    static const char command[] = "zygisk-launch";
    return request_governor(command);
}

/* fix286: the same cold start for an app the launch classes mark slow or fast to start. */
GovernorHintResult request_governor_launch_long() {
    static const char command[] = "zygisk-launch-long";
    return request_governor(command);
}

GovernorHintResult request_governor_launch_short() {
    static const char command[] = "zygisk-launch-short";
    return request_governor(command);
}

class Broker {
public:
    static Broker &instance() { static Broker broker; return broker; }

    void handle(int client) {
        int owned_pid = -1;
        uint64_t owned_ticks = 0;
        SpawnTrack spawned = SpawnTrack::none;
        for (;;) {
            const uint64_t cpu_before = cpu_us();
            AsbObserverFrame frame {};
            const int result = read_frame(client, frame);
            const int64_t now = asb_observer_boottime_ms();
            AsbObserverPolicy policy;
            load_policy_root(policy);
            Request request = Request::none;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                ++wakeups_;
                if (result == 1) {
                    // SO_PEERCRED was fixed when pre-specialize connected the socket.
                    struct ucred peer {};
                    socklen_t len = sizeof(peer);
                    const bool peer_ok = getsockopt(client, SOL_SOCKET, SO_PEERCRED, &peer, &len) == 0;
                    const bool start_ok = process_start_ticks(frame.pid) == frame.process_start_ticks &&
                                          frame.process_start_ticks != 0;
                    if (!peer_ok || peer.pid != frame.pid || !start_ok || !asb_observer_frame_valid(frame)) {
                        core_.reject_invalid();
                    } else if (frame.kind == ASB_OBSERVER_EVENT_SPAWN) {
                        request = spawn_locked(frame, policy, now, spawned);
                    } else if (spawned == SpawnTrack::tracked && core_.has(frame.pid, frame.process_start_ticks)) {
                        /* fix339: the SPAWN frame already started this record and a process fd
                         * watches its exit; the START only proves the app kept the socket. */
                        ++observe_retained_;
                        owned_pid = frame.pid;
                        owned_ticks = frame.process_start_ticks;
                    } else if (spawned == SpawnTrack::dropped) {
                        /* Rate limit, capacity or a duplicate was already counted at SPAWN. */
                    } else if (!policy.valid || !policy.observer) {
                        ++policy_absent_;
                    } else {
                        policy_generation_ = policy.generation;
                        const auto accepted = core_.start(frame, now);
                        const bool changed = accepted == AsbObserverResult::accepted;
                        if (changed) {
                            owned_pid = frame.pid;
                            owned_ticks = frame.process_start_ticks;
                            ++observe_retained_;
                        }
                        request = refresh_locked(changed, policy, now);
                    }
                } else {
                    if (result < 0) core_.reject_invalid();
                    const bool changed = owned_pid > 0 && core_.exit_if(owned_pid, owned_ticks);
                    if (changed) ++exits_peer_;
                    core_.prune(now);
                    request = refresh_locked(changed, policy, now);
                }
                ipc_cpu_us_ += cpu_us() - cpu_before;
            }
            dispatch(request, policy, now);
            if (result != 1) break;
        }
        close(client);
    }

private:
    enum class Request { none, refresh, launch, launch_long, launch_short };
    enum class SpawnTrack { none, tracked, dropped, untracked };
    struct Watch { int pid; uint64_t start_ticks; };

    /* The governor round trip (<= 100 ms) runs outside the state lock, so a slow governor
     * never stalls another app's start or exit record. */
    void dispatch(Request request, const AsbObserverPolicy &policy, int64_t now) {
        const uint64_t cpu_ipc = cpu_us();
        GovernorHintResult outcome = GovernorHintResult::unavailable;
        bool fell_back = false;
        if (request != Request::none) {
            std::lock_guard<std::mutex> ipc(ipc_mutex_);
            if (request == Request::launch_long) outcome = request_governor_launch_long();
            else if (request == Request::launch_short) outcome = request_governor_launch_short();
            else if (request == Request::launch) outcome = request_governor_launch();
            else outcome = request_governor_refresh();
            /* A governor built before fix286 does not answer the class opcodes: the
             * plain cold-start request still gets the usual lift. */
            if (outcome == GovernorHintResult::unavailable &&
                (request == Request::launch_long || request == Request::launch_short)) {
                outcome = request_governor_launch();
                fell_back = true;
            }
        }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (fell_back) ++launch_class_fallback_;
            if (request == Request::launch || request == Request::launch_long || request == Request::launch_short)
                count(outcome, launch_accepted_, launch_vetoed_, launch_unavailable_);
            if (request == Request::refresh) count(outcome, hints_accepted_, hints_vetoed_, hints_unavailable_);
            ipc_cpu_us_ += cpu_us() - cpu_ipc;
            persist_locked(now, policy);
        }
    }

    /* fix339: one thread for the whole companion, blocked in poll() on the process fds of the
     * observed apps and an eventfd that announces a new one. No timeout: it runs only when an
     * observed app exits or starts. */
    static void *reap_entry(void *self) {
        static_cast<Broker *>(self)->reap();
        return nullptr;
    }

    bool reaper_locked() {
        if (wake_fd_ < 0) {
            wake_fd_ = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
            if (wake_fd_ < 0) return false;
        }
        if (reaper_running_) return true;
        pthread_attr_t attr;
        if (pthread_attr_init(&attr) != 0) return false;
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        pthread_t thread;
        const bool ok = pthread_create(&thread, &attr, &Broker::reap_entry, this) == 0;
        pthread_attr_destroy(&attr);
        reaper_running_ = ok;
        return ok;
    }

    void wake_reaper_locked() {
        const uint64_t one = 1;
        if (write(wake_fd_, &one, sizeof(one)) < 0) { /* already pending: the reaper rescans */ }
    }

    void reap() {
        std::vector<struct pollfd> fds;
        for (;;) {
            fds.clear();
            {
                std::lock_guard<std::mutex> lock(mutex_);
                fds.push_back(pollfd{wake_fd_, POLLIN, 0});
                for (const auto &watch : watches_) fds.push_back(pollfd{watch.first, POLLIN, 0});
            }
            const int rc = poll(fds.data(), static_cast<nfds_t>(fds.size()), -1);
            if (rc < 0) {
                if (errno == EINTR) continue;
                std::lock_guard<std::mutex> lock(mutex_);
                reaper_running_ = false;
                return;
            }
            if (fds[0].revents & POLLIN) {
                uint64_t pending = 0;
                if (read(wake_fd_, &pending, sizeof(pending)) < 0) { /* nothing queued */ }
            }
            bool exited = false;
            for (size_t i = 1; i < fds.size(); ++i) if (fds[i].revents) { exited = true; break; }
            if (!exited) continue;
            const uint64_t cpu_before = cpu_us();
            const int64_t now = asb_observer_boottime_ms();
            AsbObserverPolicy policy;
            load_policy_root(policy);
            Request request = Request::none;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                ++wakeups_;
                bool changed = false;
                for (size_t i = 1; i < fds.size(); ++i) {
                    if (!fds[i].revents) continue;
                    auto it = watches_.find(fds[i].fd);
                    if (it == watches_.end()) continue;
                    if (core_.exit_if(it->second.pid, it->second.start_ticks)) { changed = true; ++exits_pidfd_; }
                    close(it->first);
                    watches_.erase(it);
                }
                core_.prune(now);
                request = refresh_locked(changed, policy, now);
                ipc_cpu_us_ += cpu_us() - cpu_before;
            }
            dispatch(request, policy, now);
        }
    }

    /* fix339: start an allowlisted app's record at SPAWN and watch its exit through a process
     * fd. Field captures had every allowlisted start come back without the socket kept in the
     * app (events_total=0), so the observer saw no process at all. */
    SpawnTrack observe_locked(const AsbObserverFrame &frame, int64_t now) {
        ++observe_requested_;
        if (watches_.size() >= ASB_OBSERVER_MAX_PROCESSES) { ++observe_untracked_; return SpawnTrack::untracked; }
        const int pidfd = open_pidfd(frame.pid);
        if (pidfd < 0) { ++observe_untracked_; return SpawnTrack::untracked; }
        if (process_start_ticks(frame.pid) != frame.process_start_ticks) { close(pidfd); return SpawnTrack::dropped; }
        if (!reaper_locked()) { close(pidfd); ++observe_untracked_; return SpawnTrack::untracked; }
        if (core_.start(frame, now) != AsbObserverResult::accepted) { close(pidfd); return SpawnTrack::dropped; }
        watches_[pidfd] = Watch{frame.pid, frame.process_start_ticks};
        ++observe_pidfd_;
        wake_reaper_locked();
        return SpawnTrack::tracked;
    }

    static uint64_t cpu_us() {
        struct timespec ts {};
        return clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts) == 0
            ? static_cast<uint64_t>(ts.tv_sec) * 1000000 + ts.tv_nsec / 1000 : 0;
    }

    static void count(GovernorHintResult r, uint64_t &ok, uint64_t &veto, uint64_t &none) {
        switch (r) {
            case GovernorHintResult::accepted: ++ok; break;
            case GovernorHintResult::vetoed: ++veto; break;
            case GovernorHintResult::unavailable: ++none; break;
        }
    }

    Request refresh_locked(bool changed, const AsbObserverPolicy &policy, int64_t now) {
        if (!changed || !policy.valid || !policy.hints) return Request::none;
        /* fix286: the governor vetoes a refresh with the screen off; when it has published
         * screen=0 the round trip (a governor wakeup per observed start or exit during sleep)
         * is not made at all. An unknown state still asks. */
        if (governor_screen_on() == 0) { ++hints_screen_off_; return Request::none; }
        if (!core_.hint_permit(now)) { ++hints_throttled_; return Request::none; }
        ++policy_hints_;
        return Request::refresh;
    }

    Request spawn_locked(const AsbObserverFrame &frame, const AsbObserverPolicy &policy, int64_t now,
                         SpawnTrack &track) {
        ++spawn_events_;
        if (!policy.valid) { ++policy_absent_; return Request::none; }
        policy_generation_ = policy.generation;
        const bool top = (frame.flags & ASB_OBSERVER_FLAG_TOP_APP) != 0;
        if ((frame.flags & ASB_OBSERVER_FLAG_LEDGER) && policy.ledger)
            core_.ledger_record(frame.package, governor_screen_on(), top, now);
        if (frame.flags & ASB_OBSERVER_FLAG_DENYLIST) ++denylist_spawns_;
        bool started = false;
        if ((frame.flags & ASB_OBSERVER_FLAG_OBSERVE) && policy.observer && policy.selected(frame.package)) {
            track = observe_locked(frame, now);
            started = track == SpawnTrack::tracked;
        }
        if (!(frame.flags & ASB_OBSERVER_FLAG_LAUNCH) || !policy.launch) return refresh_locked(started, policy, now);
        ++launch_events_;
        /* A published screen-off state already proves that the governor will veto a launch
         * lift. Do not wake it for that fixed answer: count a local veto, keep the ledger,
         * and leave the one-second launch budget untouched for the next real screen-on start.
         * Unknown state still asks the governor, exactly like the lifecycle-hint path. */
        if (governor_screen_on() == 0) {
            ++launch_screen_off_; ++launch_vetoed_;
            return Request::none;
        }
        if (!core_.launch_permit(now)) { ++launch_throttled_; return refresh_locked(started, policy, now); }
        classes_locked();
        switch (classes_.lookup(frame.package)) {
            case ASB_LAUNCH_LONG: ++launch_long_; return Request::launch_long;
            case ASB_LAUNCH_SHORT: ++launch_short_; return Request::launch_short;
            default: return Request::launch;
        }
    }

    /* fix286: re-read the launch classes only when the file changed (inode, size, mtime). A
     * missing or malformed file leaves every app on the usual cold-start lift. */
    void classes_locked() {
        struct stat st {};
        if (stat(ASB_ZYGISK_CLASSES_ABS, &st) != 0 || !S_ISREG(st.st_mode)) {
            classes_.valid = false; classes_.slow = classes_.fast = 0;
            classes_ino_ = 0; classes_size_ = -1; classes_mtime_ns_ = -1;
            return;
        }
        const int64_t mtime_ns = static_cast<int64_t>(st.st_mtim.tv_sec) * 1000000000LL + st.st_mtim.tv_nsec;
        if (static_cast<uint64_t>(st.st_ino) == classes_ino_ && static_cast<int64_t>(st.st_size) == classes_size_ &&
            mtime_ns == classes_mtime_ns_) return;
        classes_ino_ = static_cast<uint64_t>(st.st_ino);
        classes_size_ = static_cast<int64_t>(st.st_size);
        classes_mtime_ns_ = mtime_ns;
        ++classes_reads_;
        classes_.valid = false; classes_.slow = classes_.fast = 0;
        if (st.st_size <= 0 || st.st_size > static_cast<off_t>(ASB_OBSERVER_CLASSES_MAX_BYTES)) return;
        const int fd = open(ASB_ZYGISK_CLASSES_ABS, O_RDONLY | O_CLOEXEC);
        if (fd < 0) return;
        char buf[ASB_OBSERVER_CLASSES_MAX_BYTES + 1];
        const ssize_t n = read_small(fd, buf, sizeof(buf));
        close(fd);
        if (n <= 0 || static_cast<size_t>(n) > ASB_OBSERVER_CLASSES_MAX_BYTES) return;
        asb_observer_classes_parse(buf, static_cast<size_t>(n), classes_);
    }

    void persist_locked(int64_t now, const AsbObserverPolicy &policy) {
        mkdir("/dev/.asb", 0700);
        mkdir(ASB_ZYGISK_RUN_DIR, 0700);
        const std::string path = std::string(ASB_ZYGISK_RUN_DIR) + "/state." ASB_ABI_TAG ".tsv";
        const std::string tmp = path + ".tmp";
        const int fd = open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
        if (fd < 0) return;
        std::ostringstream out;
        out << "Z\tschema\t2\nZ\tmode\tobserver\nZ\tabi\t" ASB_ABI_TAG "\n";
        out << "Z\tupdated_monotonic_ms\t" << asb_observer_monotonic_ms() << "\n";
        out << "Z\tupdated_boottime_ms\t" << now << "\n";
        out << "Z\tpolicy_generation\t" << (policy.valid ? policy.generation : policy_generation_) << "\n";
        out << "Z\tpolicy_generation_seen\t" << policy_generation_ << "\n";
        out << "Z\tevents_total\t" << core_.events_total() << "\n";
        out << "Z\tevents_dropped_total\t" << core_.dropped() << "\n";
        out << "Z\tevents_dropped_rate_limit\t" << core_.rate_limited() << "\n";
        out << "Z\tevents_dropped_duplicate\t" << core_.duplicate() << "\n";
        out << "Z\tevents_dropped_invalid\t" << core_.invalid() << "\n";
        out << "Z\tevents_dropped_capacity\t" << core_.capacity_dropped() << "\n";
        out << "Z\tevents_policy_absent\t" << policy_absent_ << "\n";
        out << "Z\tipc_cpu_ms\t" << ipc_cpu_us_ / 1000 << "\n";
        out << "Z\tipc_wakeups\t" << wakeups_ << "\n";
        out << "Z\tpolicy_hints\t" << policy_hints_ << "\n";
        out << "Z\thints_accepted\t" << hints_accepted_ << "\n";
        out << "Z\thints_vetoed\t" << hints_vetoed_ << "\n";
        out << "Z\thints_unavailable\t" << hints_unavailable_ << "\n";
        out << "Z\thints_throttled\t" << hints_throttled_ << "\n";
        out << "Z\thints_screen_off\t" << hints_screen_off_ << "\n";
        out << "Z\tspawn_events\t" << spawn_events_ << "\n";
        out << "Z\tlaunch_events\t" << launch_events_ << "\n";
        out << "Z\tlaunch_accepted\t" << launch_accepted_ << "\n";
        out << "Z\tlaunch_vetoed\t" << launch_vetoed_ << "\n";
        out << "Z\tlaunch_unavailable\t" << launch_unavailable_ << "\n";
        out << "Z\tlaunch_throttled\t" << launch_throttled_ << "\n";
        out << "Z\tlaunch_screen_off\t" << launch_screen_off_ << "\n";
        out << "Z\tlaunch_long\t" << launch_long_ << "\n";
        out << "Z\tlaunch_short\t" << launch_short_ << "\n";
        out << "Z\tlaunch_class_fallback\t" << launch_class_fallback_ << "\n";
        out << "Z\tclasses_loaded\t" << (classes_.valid ? 1 : 0) << "\n";
        out << "Z\tclasses_slow\t" << (classes_.valid ? classes_.slow : 0u) << "\n";
        out << "Z\tclasses_fast\t" << (classes_.valid ? classes_.fast : 0u) << "\n";
        out << "Z\tclasses_reads\t" << classes_reads_ << "\n";
        out << "Z\tdenylist_spawns\t" << denylist_spawns_ << "\n";
        out << "Z\tobserve_requested\t" << observe_requested_ << "\n";
        out << "Z\tobserve_retained\t" << observe_retained_ << "\n";
        out << "Z\tobserve_pidfd\t" << observe_pidfd_ << "\n";
        out << "Z\tobserve_untracked\t" << observe_untracked_ << "\n";
        out << "Z\tobserve_watching\t" << watches_.size() << "\n";
        out << "Z\texits_pidfd\t" << exits_pidfd_ << "\n";
        out << "Z\texits_peer\t" << exits_peer_ << "\n";
        out << "Z\tledger_events\t" << core_.ledger_events() << "\n";
        out << "Z\tledger_evicted\t" << core_.ledger_evicted() << "\n";
        out << "Z\trss_reads\t" << rss_reads_ << "\n";
        long rss = 0;
        for (auto it = rss_cache_.begin(); it != rss_cache_.end();) {
            if (core_.processes().count(it->first)) ++it; else it = rss_cache_.erase(it);
        }
        for (const auto &entry : core_.processes()) {
            const long current_rss = cached_rss_locked(entry.first, entry.second.start_ticks, now);
            if (current_rss > 0) rss += current_rss;
            out << "P\t" << entry.first << "\t" << entry.second.start_ticks << "\t"
                << entry.second.package << "\t" << current_rss << "\n";
        }
        out << "Z\tmemory_kb\t" << rss << "\n";
        for (const auto &entry : core_.ledger()) {
            out << "L\t" << entry.first << "\t" << entry.second.screen_off << "\t"
                << entry.second.screen_on << "\t" << entry.second.top_app << "\t"
                << entry.second.burst_off << "\n";
        }
        const std::string data = out.str();
        const char *p = data.data();
        size_t left = data.size();
        while (left) {
            const ssize_t n = write(fd, p, left);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) break;
            p += n; left -= static_cast<size_t>(n);
        }
        close(fd);
        if (left == 0) rename(tmp.c_str(), path.c_str()); else unlink(tmp.c_str());
    }

    /* fix277: RSS of observed processes is re-read at most every ASB_OBSERVER_RSS_TTL_MS. The
     * state file is rewritten on every accepted frame, so a burst of process starts used to
     * reread /proc/<pid>/status of every observed process each time; the diagnostics reader
     * reads live RSS itself and uses this value only as a fallback. Bounded by processes(). */
    struct RssSample { long kb; int64_t at_ms; uint64_t start_ticks; };
    long cached_rss_locked(int pid, uint64_t start_ticks, int64_t now) {
        auto it = rss_cache_.find(pid);
        if (it != rss_cache_.end() && it->second.start_ticks == start_ticks &&
            now - it->second.at_ms >= 0 && now - it->second.at_ms < ASB_OBSERVER_RSS_TTL_MS)
            return it->second.kb;
        const long kb = process_rss_kb(pid);
        rss_cache_[pid] = RssSample{kb, now, start_ticks};
        ++rss_reads_;
        return kb;
    }

    std::mutex mutex_;
    std::mutex ipc_mutex_;
    AsbObserverCore core_;
    std::map<int, RssSample> rss_cache_;
    uint64_t rss_reads_ = 0;
    uint64_t ipc_cpu_us_ = 0;
    uint64_t wakeups_ = 0;
    uint64_t policy_hints_ = 0, hints_accepted_ = 0, hints_vetoed_ = 0;
    uint64_t hints_unavailable_ = 0, hints_throttled_ = 0, hints_screen_off_ = 0;
    uint64_t spawn_events_ = 0, launch_events_ = 0, launch_accepted_ = 0, launch_vetoed_ = 0;
    uint64_t launch_unavailable_ = 0, launch_throttled_ = 0, launch_screen_off_ = 0, policy_absent_ = 0;
    uint64_t launch_long_ = 0, launch_short_ = 0, launch_class_fallback_ = 0, denylist_spawns_ = 0;
    uint64_t classes_reads_ = 0, classes_ino_ = 0;
    uint64_t observe_requested_ = 0, observe_retained_ = 0, observe_pidfd_ = 0, observe_untracked_ = 0;
    uint64_t exits_pidfd_ = 0, exits_peer_ = 0;
    std::map<int, Watch> watches_;
    int wake_fd_ = -1;
    bool reaper_running_ = false;
    int64_t classes_size_ = -1, classes_mtime_ns_ = -1;
    AsbObserverClasses classes_;
    unsigned long policy_generation_ = 0;
};

class Observer final : public zygisk::ModuleBase {
public:
    /* Runs once in zygote. If the absolute policy path is blocked (EACCES under SELinux),
     * every fork uses the loader's module-directory fd instead of repeating a denied open. */
    void onLoad(zygisk::Api *api, JNIEnv *env) override {
        api_ = api; env_ = env;
        const int fd = open(ASB_ZYGISK_POLICY_ABS, O_RDONLY | O_CLOEXEC);
        if (fd >= 0) { close(fd); abs_path_ = true; }
        else abs_path_ = errno == ENOENT;
    }

    void preAppSpecialize(zygisk::AppSpecializeArgs *args) override {
        socket_ = -1;
        package_.clear();
        if (!args || (args->is_child_zygote && *args->is_child_zygote) ||
            !asb_observer_regular_app_uid(args->uid)) return skip();
        AsbObserverPolicy policy;
        if (!read_policy(policy) || !policy.active()) return skip();
        const bool top = args->is_top_app && *args->is_top_app;
        const bool launch = policy.launch && top;
        /* fix287: PROCESS_ON_DENYLIST is only counted. fix286 kept the library out of such
         * apps, but KernelSU marks every app without root for module unmounting by default:
         * a field capture had 462 of 465 starts flagged, and the allowlist went silent - no
         * process start, exit or lifecycle refresh for any observed app. */
        const bool hidden = (api_->getFlags() & zygisk::PROCESS_ON_DENYLIST) != 0;
        std::string base;
        if (((policy.observer && policy.packages) || policy.ledger || launch) && args->nice_name) {
            const char *raw = env_->GetStringUTFChars(args->nice_name, nullptr);
            if (raw) {
                base = asb_observer_base_package(raw);
                env_->ReleaseStringUTFChars(args->nice_name, raw);
            }
            if (!asb_observer_package_valid(base) || asb_observer_package_denied(base)) base.clear();
        }
        const bool observe = !base.empty() && policy.selected(base.c_str());
        const bool ledger = !base.empty() && policy.ledger;
        if (!observe && !launch && !ledger) return skip();
        const int sock = api_->connectCompanion();
        if (sock < 0) return skip();
        const uint32_t flags = (top ? ASB_OBSERVER_FLAG_TOP_APP : 0u) |
                               (launch ? ASB_OBSERVER_FLAG_LAUNCH : 0u) |
                               (ledger ? ASB_OBSERVER_FLAG_LEDGER : 0u) |
                               (hidden ? ASB_OBSERVER_FLAG_DENYLIST : 0u) |
                               (observe ? ASB_OBSERVER_FLAG_OBSERVE : 0u);
        /* The launch class is looked up by the companion; the name is not stored for a
         * launch-only record and never reaches the governor. fix339: an allowlisted app is
         * recorded from this frame, so its start and exit no longer depend on exemptFd. */
        const AsbObserverFrame frame = make_frame(ASB_OBSERVER_EVENT_SPAWN, flags, base);
        if (!write_all(sock, &frame, sizeof(frame))) { close(sock); return skip(); }
        /* Not allowlisted: the one-shot record is sent; nothing stays in the process. */
        if (!observe || !api_->exemptFd(sock)) { close(sock); return skip(); }
        socket_ = sock;
        package_ = base;
        // Selected processes retain the library only to own this fd. No hooks are installed.
    }

    void postAppSpecialize(const zygisk::AppSpecializeArgs *) override {
        if (socket_ < 0) return;
        if (!asb_observer_package_valid(package_) || package_.size() >= sizeof(AsbObserverFrame::package)) {
            close(socket_);
            socket_ = -1;
            return;
        }
        const AsbObserverFrame frame = make_frame(ASB_OBSERVER_EVENT_PROCESS_START, 0u, package_);
        if (!write_all(socket_, &frame, sizeof(frame))) {
            close(socket_);
            socket_ = -1;
        }
    }

    void preServerSpecialize(zygisk::ServerSpecializeArgs *) override { skip(); }

private:
    struct PolicyStamp {
        dev_t dev = 0;
        ino_t ino = 0;
        off_t size = -1;
        time_t mtime_s = 0;
        long mtime_ns = 0;
    };

    static PolicyStamp policy_stamp(const struct stat &st) {
        return PolicyStamp{st.st_dev, st.st_ino, st.st_size, st.st_mtim.tv_sec, st.st_mtim.tv_nsec};
    }

    static bool same_stamp(const PolicyStamp &a, const PolicyStamp &b) {
        return a.dev == b.dev && a.ino == b.ino && a.size == b.size &&
               a.mtime_s == b.mtime_s && a.mtime_ns == b.mtime_ns;
    }

    bool stat_policy(struct stat &st) {
        if (abs_path_) {
            if (stat(ASB_ZYGISK_POLICY_ABS, &st) == 0) return true;
            if (errno == ENOENT) return false;
        }
        const int dir = api_->getModuleDir();
        return dir >= 0 && fstatat(dir, ASB_ZYGISK_POLICY_REL, &st, 0) == 0;
    }

    int open_policy() {
        int fd = -1;
        if (abs_path_) {
            fd = open(ASB_ZYGISK_POLICY_ABS, O_RDONLY | O_CLOEXEC);
            if (fd < 0 && errno == ENOENT) return -1;
        }
        if (fd < 0) {
            const int dir = api_->getModuleDir();
            if (dir < 0) return -1;
            fd = openat(dir, ASB_ZYGISK_POLICY_REL, O_RDONLY | O_CLOEXEC);
        }
        return fd;
    }

    /* V66 dev23: atomic policy replacement gives a new inode. An unchanged policy needs one
     * stat, not another open/read/parse on every regular app fork. Every terminal error
     * invalidates the cache and returns an empty policy: a removed, denied or malformed file never leaves a
     * stale active policy in use. */
    bool read_policy(AsbObserverPolicy &policy) {
        struct stat st {};
        if (!stat_policy(st)) {
            policy = AsbObserverPolicy();
            policy_cached_ = false;
            return false;
        }
        const PolicyStamp current = policy_stamp(st);
        if (policy_cached_ && same_stamp(current, policy_stamp_)) {
            policy = cached_policy_;
            return true;
        }
        const int fd = open_policy();
        if (fd < 0) {
            policy = AsbObserverPolicy();
            policy_cached_ = false;
            return false;
        }
        struct stat opened {};
        if (fstat(fd, &opened) != 0) {
            close(fd);
            policy = AsbObserverPolicy();
            policy_cached_ = false;
            return false;
        }
        AsbObserverPolicy fresh;
        if (!load_policy_fd(fd, fresh)) {
            policy = AsbObserverPolicy();
            policy_cached_ = false;
            return false;
        }
        cached_policy_ = fresh;
        policy_stamp_ = policy_stamp(opened);
        policy_cached_ = true;
        policy = fresh;
        return true;
    }

    void skip() { api_->setOption(zygisk::DLCLOSE_MODULE_LIBRARY); }
    zygisk::Api *api_ = nullptr;
    JNIEnv *env_ = nullptr;
    bool abs_path_ = true;
    int socket_ = -1;
    std::string package_;
    bool policy_cached_ = false;
    PolicyStamp policy_stamp_ {};
    AsbObserverPolicy cached_policy_ {};
};

void companion_handler(int client) { Broker::instance().handle(client); }

} // namespace

REGISTER_ZYGISK_MODULE(Observer)
REGISTER_ZYGISK_COMPANION(companion_handler)
