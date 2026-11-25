"""TimeSystem: paces frames and advances simulation time."""

from std.time import monotonic, sleep
from larecs import System, SystemContext
from storm.resources import RunState, Time


struct TimeSystem(System):
    """Paces frames, advances simulation time, and enforces the frame limit."""

    var frame_limit: Int
    var frame_seconds: Float64
    var max_dt: Float64
    var frame_started: Int
    var next_frame: Int
    """Deadline of the next frame slot in monotonic nanoseconds."""

    def __init__(
        out self,
        frame_limit: Int = -1,
        frame_rate: Float64 = 60.0,
        max_dt: Float64 = 0.1,
    ):
        """Creates a time system with an optional frame limit.

        Args:
            frame_limit: Frames to run before stopping, or -1 for no limit.
            frame_rate: Maximum frames per second.
            max_dt: Largest timestep in seconds, so stalls such as window
                drags do not destabilize the integration.
        """
        self.frame_limit = frame_limit
        self.frame_seconds = 1.0 / frame_rate
        self.max_dt = max_dt
        self.frame_started = 0
        self.next_frame = 0

    def initialize(mut self, mut context: SystemContext[...]) raises:
        """Starts the frame clock.

        Args:
            context: World containing the RunState resource.
        """
        self.frame_started = monotonic()
        self.next_frame = self.frame_started

    def update(mut self, mut context: SystemContext[...]) raises:
        """Waits for the next frame slot, then advances time by the real
        seconds since the previous frame started, capped at `max_dt`.

        Slots lie on a fixed grid, so a late frame shortens the next wait and
        the average rate holds; after a stall of more than one slot, the grid
        restarts from the current time.

        Sets `RunState.running` to False once the frame limit is reached; the
        remaining systems still complete the current frame.

        Args:
            context: World containing the Time and RunState resources.

        Raises:
            Error: If the Time or RunState resource is missing.
        """
        var slot = Int(self.frame_seconds * 1e9)
        self.next_frame += slot
        var waiting = self.next_frame - monotonic()
        if waiting > 0:
            sleep(Float64(waiting) * 1e-9)
        var now = monotonic()
        if now - self.next_frame > slot:
            self.next_frame = now
        var dt = min(Float64(now - self.frame_started) * 1e-9, self.max_dt)
        self.frame_started = now

        ref time = context.world[].resources.get[Time]()
        time.dt = Float32(dt)
        time.absolute += time.dt

        ref run_state = context.world[].resources.get[RunState]()
        run_state.frames += 1
        if self.frame_limit > 0 and run_state.frames >= self.frame_limit:
            run_state.running = False
