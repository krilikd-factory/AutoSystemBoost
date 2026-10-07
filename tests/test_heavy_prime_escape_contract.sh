#!/usr/bin/env bash
# HEAVY prime escape: a bounded, Smart-only lift of a pinned prime ceiling. Every limit is
# the point of the feature, so each one is pinned here.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/src/asb_fsm.h"; G="$ROOT/src/asb_governor.c"; C="$ROOT/src/asb_config.h"
fail() { echo "FAIL heavy prime escape contract: $*"; exit 1; }
need() { grep -Fq -- "$2" "$1" || fail "$3"; }
need "$F" 'fsm->profile_idx == PROFILE_SMART' 'not limited to Smart'
need "$F" 'fsm->state == ASB_STATE_HEAVY && m->misc.screen_on' 'not limited to HEAVY with the screen on'
need "$F" '!fsm->thermal_cap && !m->bat.charging && !m->misc.camera_active' 'thermal/charging/camera gates missing'
need "$F" 'm->misc.app_hint < ASB_APP_GAMING' 'games are not excluded'
need "$F" 'asb_config_profile_sustained_temp_exit(&g_asb_cfg, fsm->profile_idx) &&' 'die temperature gate missing'
need "$F" 'g_asb_cfg.thermal_skin_c - 8' 'skin pre-lean gate missing'
# Burst and rest are WebUI settings now; the contract is that both stay bounded.
need "$F" 'if (_now - _esc_since >= _esc_burst)' 'burst is not time-limited'
need "$F" '_esc_rest_until = _now + _esc_rest;' 'no rest period after a burst'
need "$F" 'if (_esc_burst > 60) _esc_burst = 60;' 'burst not capped at 60 s'
need "$F" 'if (_esc_rest < 10) _esc_rest = 10;' 'rest not floored at 10 s'
need "$ROOT/src/asb_config.h" 'c->prime_escape_burst_s         = 20;' 'burst default is not 20 s'
need "$ROOT/src/asb_config.h" 'c->prime_escape_rest_s          = 40;' 'rest default is not 40 s'
need "$F" 'if (_esc_streak >= 2)' 'escape does not require the prime to stay pinned'
need "$F" 'g_profile_bounds[PROFILE_BALANCED]' 'ceiling is not bounded by Balanced'
need "$F" 'g_state_level[ASB_STATE_HEAVY]' 'bound is not the Balanced HEAVY rail'
# The escape must sit before the caps are committed and before the thermal budget runs
# (the budget lives in the governor and is applied to the committed caps afterwards).
_e="$(grep -n 'HEAVY prime escape (Smart only)' "$F" | head -1 | cut -d: -f1)"
_c="$(grep -n 'memcmp(&new_caps, &fsm->current_caps' "$F" | head -1 | cut -d: -f1)"
[ -n "$_e" ] && [ -n "$_c" ] && [ "$_e" -lt "$_c" ] || fail "escape applied after the caps are committed"
need "$C" 'c->heavy_prime_escape           = 1;' 'default not on'
need "$C" '"heavy_prime_escape"' 'config key not parsed'
grep -q '^heavy_prime_escape=1$' "$ROOT/config/governor.conf.shipped" || fail 'shipped config lacks the key'
need "$G" 'prime_escape=%d' 'state file does not publish the escape'
need "$G" 'prime_escape: lift' 'lift edge not logged'
# Multi-cluster: on 3+ cluster SoCs the middle slot is part of the burst (trigger and lift),
# and two-cluster devices must not grow a slot - the mid index exists only when slot 2 does.
need "$F" 'int _ms = (g_cpu_policy_ids[2] >= 0 && g_cpu_policy_ids[1] >= 0) ? 1 : -1;' 'mid slot not derived from topology'
need "$F" 'int _pinned = _pinned_prime || _pinned_mid;' 'mid cluster cannot trigger the burst'
need "$F" 'int _slots[2] = { _ps, _ms };' 'burst does not lift the mid cluster'
need "$F" 'if (_hw > 0 && _lim > _hw) _lim = _hw;' 'lift not bounded by hardware max'
need "$G" 'prime_escape_mid=%d' 'mid lift not published'
echo "PASS heavy prime escape contract"
