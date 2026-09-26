# Retry-After behavior

Jevlin accepts the preferred IMF-fixdate form and the legacy RFC 850 and asctime
forms described in [RFC 9110 §5.6.7](https://www.rfc-editor.org/rfc/rfc9110.html#section-5.6.7).
Date delays implement [Retry-After](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.2.3).

Local policies and implementation details:

- Valid `Retry-After-Ms` wins over `Retry-After`, independent of header order.
  Invalid occurrences do not erase valid ones; the last valid occurrence within
  each header type wins. If neither is valid, normal retry backoff applies.
- Existing fractional numeric delays remain accepted for compatibility.
- HTTP dates use wall-clock time sampled at header receipt. Past dates yield zero
  delay. Fractional remaining seconds are retained at nanosecond resolution.
- The total request deadline and subsequent sleeping still use the monotonic
  awake clock. System wall-clock skew can affect interpreting a date, but later
  wall-clock changes do not alter the already parsed delay.
- Delays saturate at 300 seconds, the maximum supported total request budget.
  A delay reaching or exceeding the remaining budget produces DeadlineExceeded
  before another attempt. Saturation cannot shorten a wait into the allowed budget.
- Calendar dates and weekdays are validated; years before 1601 are rejected.
  Leap-second notation normalizes forward into the next second. RFC 850 uses a
  rolling 50-year cutoff, including the date and time, rather than a fixed pivot.
- Parsing uses no heap allocation. Date shapes bound indexing and calendar work;
  the injected clock range is checked before standard-library year conversion.

Regression coverage includes all date forms, past/future dates, fractions, leap
and century boundaries, invalid dates, truncated input, 10,000 seeded mutations,
header precedence in both orders, and real loopback HTTP deadline integration.
The precedence test also fixes an older case where invalid milliseconds erased
an already valid standard header.
