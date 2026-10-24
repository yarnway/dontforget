from datetime import datetime
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sleep_acceptance_policy as policy


def kernel(sleep_s, wake_s, sleep_us=0, wake_us=0):
    return (f'kern.sleeptime: {{ sec = {sleep_s}, usec = {sleep_us} }}\n'
            f'kern.waketime: {{ sec = {wake_s}, usec = {wake_us} }}')


def event(wake_s, reason='DarkWake from Deep Idle due to E_RX_IP_PACKET'):
    stamp = datetime.fromtimestamp(wake_s).strftime('%Y-%m-%d %H:%M:%S')
    kind = 'DarkWake' if reason.startswith('DarkWake') else 'Wake'
    return f'{stamp} +0800 {kind} \t{reason}'


class SleepPolicyTest(unittest.TestCase):
    def test_microsecond_boundary_is_not_rounded_to_seconds(self):
        interval = policy.read_interval(kernel(100, 150, 1, 500000), 100_000_000)
        self.assertTrue(interval.covers(150))
        self.assertFalse(interval.covers(100))
        self.assertFalse(policy.SleepInterval(100_000_000, 150_000_000).covers(150))

    def test_stale_duplicate_malformed_and_inverted_pairs_are_rejected(self):
        for text in (kernel(99, 120), kernel(100, 100), kernel(101, 100),
                     kernel(100, 120, wake_us=1000000), 'missing',
                     kernel(100, 120) + '\n' + kernel(100, 120)):
            with self.subTest(text=text):
                self.assertIsNone(policy.read_interval(text, 100_000_000))

    def test_wake_reason_must_match_actual_interval(self):
        interval = policy.SleepInterval(100_000_000, 120_000_000)
        actual = event(120, 'Wake from Deep Idle RTP.keyboard/UserActivity Assertion')
        log = event(90) + '\n' + actual + '\n' + event(130)
        self.assertEqual(policy.wake_line(log, interval), actual)
        self.assertEqual(policy.wake_line(event(90), interval), '')

    def test_only_dark_wake_is_retried(self):
        cases = [(event(120), 0, 100, 1, 'retry_dark_wake'),
                 (event(120), 1, 100, 1, 'sleep_policy_changed'),
                 (event(120, 'Wake from Deep Idle RTP.keyboard/UserActivity Assertion'),
                  0, 100, 1, 'user_activity'),
                 ('', 0, 100, 1, 'non_dark_or_unknown_wake'),
                 (event(120, 'Wake from Deep Idle RTC'), 0, 100, 1, 'non_dark_or_unknown_wake'),
                 (event(120), 0, 100, 6, 'attempts_exhausted'),
                 (event(120), 0, 20, 1, 'insufficient_time')]
        for line, disabled, left, attempt, reason in cases:
            with self.subTest(reason=reason):
                self.assertEqual(policy.early_wake_decision(line, disabled, left, attempt), reason)

    def scenario(self, responses, intervals, events, *, disabled=lambda: 0, due=200):
        clock = [100.0]
        calls = []
        def request():
            calls.append(clock[0])
            return responses[len(calls) - 1]
        def read():
            s, w = intervals[len(calls) - 1]
            clock[0] = max(clock[0], w)
            return kernel(s, w)
        result = policy.observe(due, request_sleep=request, read_kernel=read,
            read_disabled=disabled, read_log=lambda: events[len(calls)-1],
            now=lambda: clock[0], pause=lambda seconds: clock.__setitem__(0, clock[0]+seconds))
        return result, calls

    def test_early_dark_wake_settles_then_later_sleep_covers_due(self):
        result, calls = self.scenario([(0, ''), (0, '')], [(101, 120), (136, 240)],
                                      [event(120), event(240)])
        self.assertEqual((result.exit_code, result.reason), (0, 'due_inside_sleep'))
        self.assertEqual(calls, [100, 135])
        self.assertEqual(len(result.intervals), 2)

    def test_user_wake_stops_without_second_request(self):
        result, calls = self.scenario([(0, '')], [(101, 120)],
            [event(120, 'Wake from Deep Idle RTP.keyboard/UserActivity Assertion')])
        self.assertEqual(result.reason, 'user_activity')
        self.assertEqual(len(calls), 1)

    def test_not_permitted_is_execution_failure_and_never_retried(self):
        result, calls = self.scenario([(71, 'Unable to sleep system: error 0xe00002e2')], [], [])
        self.assertEqual((result.exit_code, result.reason, result.request_returncode),
                         (2, 'sleep_request_not_permitted', 71))
        self.assertEqual(len(calls), 1)

    def test_power_policy_change_prevents_any_request(self):
        result, calls = self.scenario([], [], [], disabled=lambda: 1)
        self.assertEqual(result.reason, 'sleep_policy_changed')
        self.assertEqual(calls, [])

    def test_policy_change_during_settle_prevents_the_next_request(self):
        reads = [0]
        def disabled():
            reads[0] += 1
            return 0 if reads[0] <= 2 else 1
        result, calls = self.scenario([(0, '')], [(101, 120)], [event(120)],
                                      disabled=disabled)
        self.assertEqual(result.reason, 'sleep_policy_changed')
        self.assertEqual(len(calls), 1)

    def test_rejection_after_dark_wake_has_failure_status_without_more_retries(self):
        result, calls = self.scenario([(0, ''), (71, 'error 0xe00002e2')],
                                      [(101, 120)], [event(120)])
        self.assertEqual((result.exit_code, result.request_returncode), (2, 71))
        self.assertEqual(len(calls), 2)

    def test_dark_wake_retry_count_is_bounded(self):
        intervals = [(101 + 25 * i, 110 + 25 * i) for i in range(6)]
        result, calls = self.scenario([(0, '')] * 6, intervals,
                                      [event(w) for _, w in intervals], due=500)
        self.assertEqual(result.reason, 'attempts_exhausted')
        self.assertEqual(len(calls), 6)

    def test_missing_pair_has_bounded_deadline(self):
        clock = [100]
        result = policy.observe(200, request_sleep=lambda: (0, ''),
            read_kernel=lambda: kernel(10, 20), read_disabled=lambda: 0, read_log=lambda: '',
            now=lambda: clock[0], pause=lambda seconds: clock.__setitem__(0, clock[0]+seconds))
        self.assertEqual(result.reason, 'no_new_sleep_wake_pair')
        self.assertEqual(clock[0], 350)

    def test_reader_exception_has_one_unambiguous_failure_status(self):
        def fail():
            raise OSError('private diagnostic detail')
        events = []
        result = policy.observe(200, request_sleep=fail, read_kernel=lambda: '',
            read_disabled=lambda: 0, read_log=lambda: '', now=lambda: 100,
            emit=lambda *args: events.append(args))
        self.assertEqual((result.exit_code, result.reason), (2, 'observation_exception'))
        self.assertNotIn('private diagnostic detail', str(events))


if __name__ == '__main__':
    unittest.main()
