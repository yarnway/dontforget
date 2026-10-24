"""Bounded sleep observation policy; this module never changes power settings.

The local administrator runner owns preparation and restoration. Injected readers
and request functions keep the policy testable without sleeping the test machine.
"""

from dataclasses import dataclass, field
from datetime import datetime
import re
import time


@dataclass(frozen=True)
class SleepInterval:
    sleep_us: int
    wake_us: int

    def covers(self, due_epoch):
        return self.sleep_us < due_epoch * 1_000_000 < self.wake_us


def read_interval(text, started_us):
    values = {}
    for name in ('sleeptime', 'waketime'):
        matches = re.findall(
            rf'^kern\.{name}:\s*\{{\s*sec = (\d+), usec = (\d+)\s*\}}',
            text, re.MULTILINE)
        if len(matches) != 1:
            return None
        seconds, micros = map(int, matches[0])
        if micros >= 1_000_000:
            return None
        values[name] = seconds * 1_000_000 + micros
    if not started_us <= values['sleeptime'] < values['waketime']:
        return None
    return SleepInterval(values['sleeptime'], values['waketime'])


def wake_line(log, interval):
    # pmset prints local wall time. Select the actual wake second, never an
    # earlier dark wake or a later assertion mentioning the word "wake".
    prefix = datetime.fromtimestamp(interval.wake_us / 1_000_000).strftime(
        '%Y-%m-%d %H:%M:%S')
    matches = [line for line in log.splitlines()
               if line.startswith(prefix) and
               re.search(r'\s(?:DarkWake|Wake)\s+.*(?:DarkWake|Wake) from ', line)]
    return matches[-1] if matches else ''


def early_wake_decision(line, sleep_disabled, seconds_left, attempt,
                        max_attempts=6, settle_seconds=15):
    if sleep_disabled != 0:
        return 'sleep_policy_changed'
    if any(value in line for value in ('UserActivity', 'RTP.keyboard', 'HID Activity')):
        return 'user_activity'
    if not re.search(r'\sDarkWake\s+.*DarkWake from ', line):
        return 'non_dark_or_unknown_wake'
    if attempt >= max_attempts:
        return 'attempts_exhausted'
    if seconds_left <= settle_seconds + 5:
        return 'insufficient_time'
    return 'retry_dark_wake'


@dataclass
class Observation:
    exit_code: int
    reason: str
    attempts: int
    intervals: list = field(default_factory=list)
    request_returncode: int = 0


def observe(due_epoch, *, request_sleep, read_kernel, read_disabled,
            read_log, now=time.time, pause=time.sleep, emit=lambda *_: None,
            max_attempts=6, settle_seconds=15):
    """Observe real intervals; retry only known early dark wakes, never denial.

    Return 0 for an interval covering the due instant, 4 for an inconclusive or
    interrupted observation, and 2 for an execution error. Restoration belongs
    to the caller and can override these results if it fails.
    """
    if not 1 <= max_attempts <= 6 or not 10 <= settle_seconds <= 30:
        raise ValueError('Unsafe observation bounds')
    deadline = min(now() + 420, due_epoch + 150)
    intervals = []
    attempt = 0
    try:
        for attempt in range(1, max_attempts + 1):
            if read_disabled() != 0:
                return Observation(4, 'sleep_policy_changed', attempt - 1, intervals)
            if now() >= due_epoch - 5 or now() >= deadline:
                return Observation(4, 'insufficient_time', attempt - 1, intervals)
            started_us = int(now() * 1_000_000)
            emit('SLEEP_REQUEST', attempt)
            code, error = request_sleep()
            if code:
                reason = ('sleep_request_not_permitted' if '0xe00002e2' in error.lower()
                          else 'sleep_request_rejected')
                return Observation(2, reason, attempt, intervals, code)
            while now() < deadline:
                pause(min(5, deadline - now()))
                interval = read_interval(read_kernel(), started_us)
                if interval is None:
                    continue
                intervals.append({'sleep_us': interval.sleep_us,
                                  'wake_us': interval.wake_us,
                                  'covers_due': interval.covers(due_epoch)})
                emit('KERNEL_SLEEP_INTERVAL', intervals[-1])
                if interval.covers(due_epoch):
                    return Observation(0, 'due_inside_sleep', attempt, intervals)
                decision = early_wake_decision(
                    wake_line(read_log(), interval), read_disabled(),
                    due_epoch - now(), attempt, max_attempts, settle_seconds)
                emit('EARLY_WAKE_DECISION', decision)
                if decision != 'retry_dark_wake':
                    return Observation(4, decision, attempt, intervals)
                pause(settle_seconds)
                break
            else:
                return Observation(4, 'no_new_sleep_wake_pair', attempt, intervals)
    except Exception as error:
        # Exception bodies can contain unrelated system details. Keep the type.
        emit('OBSERVATION_EXCEPTION_TYPE', type(error).__name__)
        return Observation(2, 'observation_exception', attempt, intervals)
    return Observation(4, 'attempts_exhausted', attempt, intervals)
