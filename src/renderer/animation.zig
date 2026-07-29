//! Animation primitives for the renderer.

const std = @import("std");

/// A critically damped spring.
///
/// `position` is the *remaining* offset from the target, so zero means
/// settled. Callers add to it to displace the spring and then step it
/// toward zero every frame. Expressing it this way (rather than as a
/// current/target pair) is what makes stacking work: two displacements
/// that arrive a frame apart simply sum, and the spring glides the total
/// back to zero without either one restarting the other.
///
/// The update is the analytical solution to the critically damped
/// harmonic oscillator rather than a numerical integration, so the step
/// is exact for any `dt` and cannot blow up when a frame is late.
///
/// Based on Neovide's implementation, which in turn follows the PD
/// controller formulation from
/// https://gdcvault.com/play/1027059/Math-In-Game-Development-Summit
pub const Spring = struct {
    /// Remaining offset from the target. Zero is settled.
    position: f32 = 0,

    /// Current velocity.
    velocity: f32 = 0,

    /// How close to zero the position must get before we call it settled
    /// and snap. In our use the unit is terminal rows, so this is well
    /// under a pixel at any sane cell height.
    const epsilon: f32 = 0.01;

    /// Step the spring forward by `dt` seconds.
    ///
    /// `duration` is roughly how long a displacement takes to decay to
    /// ~2% of its initial size. `zeta` is the damping ratio: 1.0 is
    /// critically damped (no overshoot), below 1.0 is underdamped and
    /// will oscillate.
    ///
    /// Returns true if the spring is still animating.
    pub fn update(
        self: *Spring,
        dt: f32,
        duration: f32,
        zeta: f32,
    ) bool {
        // A frame this long would complete the whole animation, so
        // there is nothing to interpolate. This also guards the
        // division below against a zero or negative duration.
        if (duration <= dt) {
            self.reset();
            return false;
        }

        // Already settled.
        if (self.position == 0) return false;

        // Chosen so the displacement decays to ~2% over `duration`.
        const omega = 4.0 / (zeta * duration);

        // Analytical solution for the critically damped oscillator with
        // initial conditions position = a and velocity = b - a*omega.
        const a = self.position;
        const b = self.position * omega + self.velocity;
        const decay = @exp(-omega * dt);

        self.position = (a + b * dt) * decay;
        self.velocity = decay * (-a * omega - b * dt * omega + b);

        // The exponential never actually reaches zero, so snap once
        // we're close enough to stop scheduling frames for it.
        if (@abs(self.position) < epsilon) {
            self.reset();
            return false;
        }

        return true;
    }

    /// Return to rest immediately, discarding any in-flight motion.
    pub fn reset(self: *Spring) void {
        self.position = 0;
        self.velocity = 0;
    }

    /// Whether the spring currently has any offset to animate away.
    pub fn animating(self: *const Spring) bool {
        return self.position != 0;
    }
};

/// How long after a wheel or trackpad scroll a region scroll is still
/// attributed to that scroll.
///
/// This has to be long enough to cover the round trip (the surface writes
/// the terminal, the application reacts, the renderer sees the jump) plus
/// the gap between two events of a slow drag, and short enough that a
/// keypress right after a scroll isn't mistaken for part of it. Human
/// scroll-then-type gaps are far longer than this; application round trips
/// are far shorter.
pub const wheel_recency_window_ns: u64 = 150 * std.time.ns_per_ms;

/// What to do with the scroll spring for one frame.
pub const ScrollAction = enum {
    /// Nothing changed; keep animating whatever is in flight.
    none,

    /// Displace the spring by the jump and animate it away.
    glide,

    /// Snap to the new content immediately, cancelling any glide.
    snap,
};

/// Decide what a frame's observed region scroll should do to the spring.
///
/// This is the wheel-recency gate. Split out as a pure function because
/// its correctness is the whole feature (a wrong answer here means either
/// keyboard motion lags or wheel motion doesn't animate) and it is not
/// otherwise reachable from a test.
///
/// `now` and `last_wheel` are monotonic; `last_wheel` is null if the user
/// has never scrolled. `jump_rows` is the region shift observed this frame.
pub fn scrollAction(
    opts: struct {
        /// Whether the alternate screen is active. The primary screen has
        /// its own (phase 1) pixel scrolling and must never spring.
        alternate: bool,

        /// Configured animation duration in seconds. Zero disables.
        duration: f32,

        /// Rows the scrolling region shifted this frame.
        jump_rows: isize,

        /// Whether the region bounds changed since the last frame. A
        /// glide computed for the old bounds would land in the wrong
        /// place under the new ones.
        region_changed: bool,

        now: std.time.Instant,
        last_wheel: ?std.time.Instant,
    },
) ScrollAction {
    // Animation off, or a screen that doesn't animate: never leave an
    // offset applied.
    if (opts.duration <= 0) return .snap;
    if (!opts.alternate) return .snap;

    // New region bounds invalidate any in-flight glide. Snap even if
    // this frame also carries a jump; the jump belongs to the new
    // layout and gliding it would drag the old offset along.
    if (opts.region_changed) return .snap;

    // No scroll happened, so nothing to decide. Note this is NOT `snap`:
    // most frames land here and snapping would kill every animation
    // after its first frame.
    if (opts.jump_rows == 0) return .none;

    // A scroll happened. It animates only if a wheel event is recent
    // enough to be its cause; otherwise it was the keyboard (or the
    // application on its own) and must be instant.
    const last = opts.last_wheel orelse return .snap;

    // A timestamp from the future means the clock moved under us.
    // Treat it as not recent rather than as infinitely recent.
    if (opts.now.order(last) == .lt) return .snap;

    return if (opts.now.since(last) <= wheel_recency_window_ns)
        .glide
    else
        .snap;
}

/// The spring displacement, in rows, for an observed region scroll.
///
/// This is the sign convention of the whole feature, so it is worth
/// deriving rather than asserting.
///
/// By the time the renderer observes a jump, the terminal grid ALREADY
/// holds the post-scroll content. What the user last saw is the
/// pre-scroll frame. The animation's job is to draw the new content at
/// the OLD content's apparent position and then glide it to its real
/// one, so the spring must start displaced by the amount that undoes
/// the jump.
///
/// `jump_rows` is positive when content moved DOWN (insertLines, reverse
/// index). Screen-space +Y is also down. So:
///
///   - Content moved UP one row (`jump_rows = -1`, the ordinary case of
///     scrolling forward through a file): a line that was on row 5 is
///     now on row 4. To put it back under the user's eye we draw it one
///     row DOWN, i.e. a POSITIVE offset.
///   - Content moved DOWN one row (`jump_rows = +1`): symmetric, a
///     NEGATIVE offset.
///
/// The displacement is therefore the negation of the jump. Getting this
/// backwards does not merely fail to animate: it shifts the content
/// FURTHER in the direction it just travelled, doubling the visible
/// jump, and then springs back — a lurch away and a rebound rather than
/// a glide.
pub fn springDisplacement(jump_rows: isize) f32 {
    return -@as(f32, @floatFromInt(jump_rows));
}

test "spring displacement undoes the jump rather than repeating it" {
    const testing = std.testing;

    // Content moved up (scrolling forward): draw it lower, so positive.
    try testing.expectEqual(@as(f32, 3), springDisplacement(-3));

    // Content moved down (scrolling back): draw it higher, so negative.
    try testing.expectEqual(@as(f32, -3), springDisplacement(3));

    // No jump, no displacement.
    try testing.expectEqual(@as(f32, 0), springDisplacement(0));

    // The displacement always opposes the jump. This is the property
    // that failed on device: same-sign displacement moves content
    // further along its own direction of travel, which reads as a lurch
    // away followed by a rebound.
    for ([_]isize{ -8, -1, 1, 8 }) |jump| {
        const d = springDisplacement(jump);
        const j: f32 = @floatFromInt(jump);
        try testing.expect(d * j < 0);
        try testing.expectApproxEqAbs(@abs(j), @abs(d), 1e-6);
    }
}

test "a glide converges on zero offset from the undo displacement" {
    const testing = std.testing;

    // End to end: the offset starts at the full undo of the jump (the
    // content appears exactly where it was before) and decays to zero
    // (the content is where it really is), never crossing to the far
    // side, which is what a rebound would look like.
    var spring: Spring = .{ .position = springDisplacement(-4) };
    try testing.expectEqual(@as(f32, 4), spring.position);

    var i: usize = 0;
    while (i < 240 and spring.animating()) : (i += 1) {
        _ = spring.update(1.0 / 120.0, 0.15, 1.0);
        try testing.expect(spring.position >= 0);
        try testing.expect(spring.position <= 4);
    }
    try testing.expect(!spring.animating());
    try testing.expectEqual(@as(f32, 0), spring.position);
}

/// Test helper: a monotonic instant `ns` after an arbitrary origin.
fn testInstant(ns: u64) std.time.Instant {
    // std.time.Instant's representation is platform-specific, so build
    // one by hand rather than assuming a field layout.
    return switch (@typeInfo(@TypeOf(@as(std.time.Instant, undefined).timestamp))) {
        .@"struct" => .{ .timestamp = .{
            .sec = @intCast(ns / std.time.ns_per_s),
            .nsec = @intCast(ns % std.time.ns_per_s),
        } },
        else => .{ .timestamp = @intCast(ns) },
    };
}

test "wheel gate: recent wheel glides, stale wheel snaps" {
    const testing = std.testing;

    const base = 10 * std.time.ns_per_s;
    const common = .{
        .alternate = true,
        .duration = 0.15,
        .jump_rows = -3,
        .region_changed = false,
    };

    // Immediately after a wheel event.
    try testing.expectEqual(ScrollAction.glide, scrollAction(.{
        .alternate = common.alternate,
        .duration = common.duration,
        .jump_rows = common.jump_rows,
        .region_changed = common.region_changed,
        .now = testInstant(base),
        .last_wheel = testInstant(base),
    }));

    // Just inside the window.
    try testing.expectEqual(ScrollAction.glide, scrollAction(.{
        .alternate = common.alternate,
        .duration = common.duration,
        .jump_rows = common.jump_rows,
        .region_changed = common.region_changed,
        .now = testInstant(base + wheel_recency_window_ns),
        .last_wheel = testInstant(base),
    }));

    // Just outside it: this is the keyboard case.
    try testing.expectEqual(ScrollAction.snap, scrollAction(.{
        .alternate = common.alternate,
        .duration = common.duration,
        .jump_rows = common.jump_rows,
        .region_changed = common.region_changed,
        .now = testInstant(base + wheel_recency_window_ns + 1),
        .last_wheel = testInstant(base),
    }));

    // Never scrolled at all.
    try testing.expectEqual(ScrollAction.snap, scrollAction(.{
        .alternate = common.alternate,
        .duration = common.duration,
        .jump_rows = common.jump_rows,
        .region_changed = common.region_changed,
        .now = testInstant(base),
        .last_wheel = null,
    }));
}

test "wheel gate: no jump leaves the spring alone" {
    const testing = std.testing;

    const base = 10 * std.time.ns_per_s;
    try testing.expectEqual(ScrollAction.none, scrollAction(.{
        .alternate = true,
        .duration = 0.15,
        .jump_rows = 0,
        .region_changed = false,
        .now = testInstant(base),
        .last_wheel = testInstant(base),
    }));

    // Even with no recent wheel: an idle frame must not cancel a glide
    // that a previous frame started.
    try testing.expectEqual(ScrollAction.none, scrollAction(.{
        .alternate = true,
        .duration = 0.15,
        .jump_rows = 0,
        .region_changed = false,
        .now = testInstant(base + 10 * std.time.ns_per_s),
        .last_wheel = testInstant(base),
    }));
}

test "wheel gate: disabled, primary screen, and region change all snap" {
    const testing = std.testing;

    const base = 10 * std.time.ns_per_s;

    // Animation disabled by config.
    try testing.expectEqual(ScrollAction.snap, scrollAction(.{
        .alternate = true,
        .duration = 0,
        .jump_rows = -3,
        .region_changed = false,
        .now = testInstant(base),
        .last_wheel = testInstant(base),
    }));

    // Primary screen: phase 1 owns it, the spring must stay out.
    try testing.expectEqual(ScrollAction.snap, scrollAction(.{
        .alternate = false,
        .duration = 0.15,
        .jump_rows = -3,
        .region_changed = false,
        .now = testInstant(base),
        .last_wheel = testInstant(base),
    }));

    // Region bounds changed under an otherwise animatable jump.
    try testing.expectEqual(ScrollAction.snap, scrollAction(.{
        .alternate = true,
        .duration = 0.15,
        .jump_rows = -3,
        .region_changed = true,
        .now = testInstant(base),
        .last_wheel = testInstant(base),
    }));

    // Region change with no jump also snaps, so a stale offset can't
    // survive into the new layout.
    try testing.expectEqual(ScrollAction.snap, scrollAction(.{
        .alternate = true,
        .duration = 0.15,
        .jump_rows = 0,
        .region_changed = true,
        .now = testInstant(base),
        .last_wheel = testInstant(base),
    }));
}

test "wheel gate: a wheel timestamp from the future snaps" {
    const testing = std.testing;

    const base = 10 * std.time.ns_per_s;
    try testing.expectEqual(ScrollAction.snap, scrollAction(.{
        .alternate = true,
        .duration = 0.15,
        .jump_rows = -3,
        .region_changed = false,
        .now = testInstant(base),
        .last_wheel = testInstant(base + std.time.ns_per_s),
    }));
}

test "spring settles" {
    const testing = std.testing;

    var s: Spring = .{ .position = 10 };
    try testing.expect(s.animating());

    // Step at 120Hz for well past the animation duration. It must
    // settle, and it must settle by decaying rather than by hitting
    // the duration <= dt shortcut.
    var i: usize = 0;
    var animating = true;
    while (i < 240 and animating) : (i += 1) {
        animating = s.update(1.0 / 120.0, 0.15, 1.0);
    }

    try testing.expect(!animating);
    try testing.expectEqual(@as(f32, 0), s.position);
    try testing.expectEqual(@as(f32, 0), s.velocity);

    // 0.15s at 120Hz is 18 frames; the 2% tolerance plus our epsilon
    // means it takes somewhat longer, but nowhere near our 240 cap.
    try testing.expect(i < 120);
}

test "spring decays monotonically toward zero" {
    const testing = std.testing;

    var s: Spring = .{ .position = 8 };
    var last = s.position;
    for (0..10) |_| {
        _ = s.update(1.0 / 120.0, 0.15, 1.0);
        // Critically damped: never overshoots past zero, and always
        // makes progress toward it.
        try testing.expect(s.position >= 0);
        try testing.expect(s.position < last);
        last = s.position;
    }
}

test "spring accumulates displacements" {
    const testing = std.testing;

    var s: Spring = .{};
    s.position += 3;
    _ = s.update(1.0 / 120.0, 0.15, 1.0);

    // A second displacement arriving mid-flight stacks onto whatever
    // is left of the first rather than replacing it.
    const mid = s.position;
    try testing.expect(mid > 0);
    s.position += 3;
    try testing.expectApproxEqAbs(mid + 3, s.position, 1e-6);
}

test "spring resets" {
    const testing = std.testing;

    var s: Spring = .{ .position = 5 };
    _ = s.update(1.0 / 120.0, 0.15, 1.0);
    try testing.expect(s.velocity != 0);

    s.reset();
    try testing.expectEqual(@as(f32, 0), s.position);
    try testing.expectEqual(@as(f32, 0), s.velocity);
    try testing.expect(!s.animating());
    try testing.expect(!s.update(1.0 / 120.0, 0.15, 1.0));
}

test "spring snaps when a frame covers the whole animation" {
    const testing = std.testing;

    var s: Spring = .{ .position = 100 };
    try testing.expect(!s.update(0.2, 0.15, 1.0));
    try testing.expectEqual(@as(f32, 0), s.position);

    // A zero duration means animation is off; the guard has to catch
    // that too rather than dividing by zero.
    var off: Spring = .{ .position = 100 };
    try testing.expect(!off.update(1.0 / 120.0, 0, 1.0));
    try testing.expectEqual(@as(f32, 0), off.position);
}

test "spring handles negative displacement symmetrically" {
    const testing = std.testing;

    var up: Spring = .{ .position = 6 };
    var down: Spring = .{ .position = -6 };
    for (0..8) |_| {
        _ = up.update(1.0 / 120.0, 0.15, 1.0);
        _ = down.update(1.0 / 120.0, 0.15, 1.0);
    }
    try testing.expectApproxEqAbs(up.position, -down.position, 1e-5);
}

test "wheel scroll glides and a following keypress cancels it" {
    const testing = std.testing;

    // This is the sequence from the spec's hard requirement, run
    // through the two pieces together: scroll with the trackpad, then
    // hit a key before the glide has finished.
    const duration: f32 = 0.15;
    const zeta: f32 = 1.0;
    const frame = 1.0 / 120.0;
    const wheel_at = 10 * std.time.ns_per_s;

    var spring: Spring = .{};
    var t: u64 = wheel_at;

    // The application scrolls its region 3 rows in response to the
    // wheel. That animates.
    try testing.expectEqual(ScrollAction.glide, scrollAction(.{
        .alternate = true,
        .duration = duration,
        .jump_rows = -3,
        .region_changed = false,
        .now = testInstant(t),
        .last_wheel = testInstant(wheel_at),
    }));
    spring.position += springDisplacement(-3);

    // Content moved up, so it is drawn lower and glides up into place.
    try testing.expect(spring.position > 0);

    // Run a few frames. The glide is in flight and has not settled.
    for (0..4) |_| {
        t += @intFromFloat(frame * std.time.ns_per_s);
        try testing.expectEqual(ScrollAction.none, scrollAction(.{
            .alternate = true,
            .duration = duration,
            .jump_rows = 0,
            .region_changed = false,
            .now = testInstant(t),
            .last_wheel = testInstant(wheel_at),
        }));
        try testing.expect(spring.update(frame, duration, zeta));
    }
    try testing.expect(spring.animating());

    // Now the user presses j, well after the wheel window. The
    // resulting jump must snap, and must take the in-flight glide with
    // it: this is the "keyboard motion is never delayed" requirement.
    t = wheel_at + wheel_recency_window_ns + std.time.ns_per_ms;
    try testing.expectEqual(ScrollAction.snap, scrollAction(.{
        .alternate = true,
        .duration = duration,
        .jump_rows = -1,
        .region_changed = false,
        .now = testInstant(t),
        .last_wheel = testInstant(wheel_at),
    }));
    spring.reset();
    try testing.expect(!spring.animating());
}

test "a flick of several wheel scrolls stacks into one glide" {
    const testing = std.testing;

    const duration: f32 = 0.15;
    const frame = 1.0 / 120.0;
    var t: u64 = 10 * std.time.ns_per_s;
    var spring: Spring = .{};

    // Three scrolls a couple of frames apart, each of them still
    // inside the recency window of its own wheel event.
    var total: f32 = 0;
    for (0..3) |_| {
        try testing.expectEqual(ScrollAction.glide, scrollAction(.{
            .alternate = true,
            .duration = duration,
            .jump_rows = -3,
            .region_changed = false,
            .now = testInstant(t),
            .last_wheel = testInstant(t),
        }));
        const before = spring.position;
        spring.position += springDisplacement(-3);
        total += 3;

        // Each one adds to what is left rather than replacing it, so
        // the motion reads as continuous. All three scrolls go the same
        // way, so the offset stays on one side of zero throughout: it
        // never crosses over, which is what a rebound would look like.
        try testing.expectApproxEqAbs(before + 3, spring.position, 1e-6);
        try testing.expect(spring.position > 0);

        for (0..2) |_| {
            _ = spring.update(frame, duration, 1.0);
            t += @intFromFloat(frame * std.time.ns_per_s);
        }
    }

    // The stack never exceeds the total distance scrolled (the spring
    // has been decaying the whole time).
    try testing.expect(@abs(spring.position) < total);
    try testing.expect(spring.animating());

    // And it does eventually settle on its own.
    var i: usize = 0;
    while (i < 240 and spring.animating()) : (i += 1) {
        _ = spring.update(frame, duration, 1.0);
    }
    try testing.expect(!spring.animating());
}

test {
    _ = Spring;
}
