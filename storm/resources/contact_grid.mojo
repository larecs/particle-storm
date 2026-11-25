"""ContactGrid and ContactCounts resources for particle contacts."""

from std.math import cos, pi, sin, sqrt
from larecs import (
    AtomicView,
    DevicePassableResource,
    ResourceAccess,
    ResourceAdapter,
    ResourceDeviceCache,
)
from storm.components import Deposit, Position, Velocity
from storm.resources.bounds import Bounds


@fieldwise_init
struct _GridShape(TrivialRegisterPassable):
    """Cell layout and contact parameters shared by all grid views."""

    var columns: Int
    var rows: Int
    var radius: Float32
    """Contact radius of a particle in meters."""
    var rest_speed: Float32
    """Speed in meters per second below which a particle joins the grid."""
    var cells_per_meter_x: Float32
    var cells_per_meter_y: Float32
    var bounds: Bounds
    """Periodic domain size the grid covers."""

    def cells(self) -> Int:
        """Returns the number of cells.

        Returns:
            Columns times rows.
        """
        return self.columns * self.rows

    @always_inline
    def cell(self, position: Position) -> Int:
        """Returns the index of the cell containing a wrapped position.

        Args:
            position: Position inside the domain in meters.

        Returns:
            Row-major cell index.
        """
        var column = min(
            Int(position.x * self.cells_per_meter_x), self.columns - 1
        )
        var row = min(Int(position.y * self.cells_per_meter_y), self.rows - 1)
        return max(row, 0) * self.columns + max(column, 0)

    @always_inline
    def slow(self, velocity: Velocity) -> Bool:
        """Returns whether a particle is slow enough to rest.

        Args:
            velocity: Particle velocity in meters per second.

        Returns:
            True if the speed is below `rest_speed`.
        """
        return (
            velocity.dx * velocity.dx + velocity.dy * velocity.dy
            < self.rest_speed * self.rest_speed
        )

    @always_inline
    def resting(self, velocity: Velocity, deposit: Deposit) -> Bool:
        """Returns whether a particle belongs in the grid.

        Args:
            velocity: Particle velocity in meters per second.
            deposit: Particle's pile state from the previous pass.

        Returns:
            True if the particle is supported and slow.
        """
        return deposit.supported() and self.slow(velocity)


@always_inline
def _increment(counter: Pointer[UInt32, MutUntrackedOrigin]) -> Int:
    """Atomically increments a counter.

    Args:
        counter: Counter shared by concurrent writers.

    Returns:
        The value before the increment.
    """
    return Int(
        AtomicView[True, UInt32, MutUntrackedOrigin](
            unsafe_pointer=counter
        ).fetch_add(1)
    )


def _mut[
    T: Movable & Deinitable
](values: List[T]) -> Pointer[T, MutUntrackedOrigin]:
    """Addresses host backing storage for a writer view.

    Parameters:
        T: Element type.

    Args:
        values: Leased source buffer.

    Returns:
        Untracked mutable pointer valid during the invocation.
    """
    return Pointer[T, MutUntrackedOrigin](
        unsafe_from_address=Int(values.unsafe_ptr())
    )


def _imm[
    T: Movable & Deinitable
](values: List[T]) -> Pointer[T, ImmUntrackedOrigin]:
    """Addresses host backing storage for a read view.

    Parameters:
        T: Element type.

    Args:
        values: Leased source buffer.

    Returns:
        Untracked immutable pointer valid during the invocation.
    """
    return Pointer[T, ImmUntrackedOrigin](
        unsafe_from_address=Int(values.unsafe_ptr())
    )


@fieldwise_init
struct ContactCountsRead(TrivialRegisterPassable):
    """Read view over resting particles per cell."""

    var counts: Pointer[UInt32, ImmUntrackedOrigin]


@fieldwise_init
struct ContactCountsFill(TrivialRegisterPassable):
    """Writer view that counts resting particles per cell."""

    var counts: Pointer[UInt32, MutUntrackedOrigin]
    var shape: _GridShape

    @always_inline
    def add(self, position: Position, velocity: Velocity, deposit: Deposit):
        """Counts a particle in its cell if it is resting.

        Args:
            position: Wrapped particle position in meters.
            velocity: Particle velocity in meters per second.
            deposit: Particle's pile state.
        """
        if self.shape.resting(velocity, deposit):
            _ = _increment(
                Pointer(to=self.counts[unsafe_offset=self.shape.cell(position)])
            )


struct ContactCounts(DevicePassableResource):
    """Number of resting particles in each grid cell."""

    comptime Adapter = ContactCountsAdapter
    var shape: _GridShape
    var counts: List[UInt32]

    def __init__(out self, grid: ContactGrid):
        """Creates zero counts for a grid's cell layout.

        Args:
            grid: Grid whose layout to count into.
        """
        self.shape = grid.shape
        self.counts = List[UInt32](length=grid.shape.cells(), fill=0)


struct ContactCountsAdapter(ResourceAdapter):
    """Selects ContactCountsRead for `read` and ContactCountsFill otherwise.

    `write` access starts every run from zero counts.
    """

    comptime Source = ContactCounts
    comptime View[mutable: Bool] = (
        ContactCountsFill if mutable else ContactCountsRead
    )
    comptime supports_mutation = True
    # Counters are incremented atomically.
    comptime supports_concurrent_mutation = True

    @staticmethod
    def validate(source: Self.Source) raises:
        """Checks the buffer size against the cell layout.

        Args:
            source: Current counts.

        Raises:
            Error: If the buffer does not match the layout.
        """
        if len(source.counts) != source.shape.cells():
            raise Error("ContactCounts does not match its cell layout")

    @staticmethod
    def bind_host(source: Self.Source) raises -> Self.View[False]:
        """Borrows host counts.

        Args:
            source: Validated counts.

        Raises:
            Error: Never.

        Returns:
            Read view over host counts.
        """
        return {_imm(source.counts)}

    @staticmethod
    def prepare_device(
        source: Self.Source, mut cache: ResourceDeviceCache
    ) raises -> Self.View[False]:
        """Uploads counts for a read view.

        Args:
            source: Validated counts.
            cache: Leased cache.

        Raises:
            Error: If the upload fails.

        Returns:
            Read view over device counts.
        """
        return {cache.upload[UInt32](0, Span(source.counts))}

    @staticmethod
    def bind_host_mutable[
        access: ResourceAccess
    ](mut source: Self.Source) raises -> Self.View[True]:
        """Zeroes counts for `write`, then borrows them.

        Parameters:
            access: `WRITE` or `READ_WRITE`.

        Args:
            source: Validated counts.

        Raises:
            Error: Never.

        Returns:
            Writer view over host counts.
        """
        comptime if not access.preserves_contents():
            for ref count in source.counts:
                count = 0
        return {_mut(source.counts), source.shape}

    @staticmethod
    def prepare_device_mutable[
        access: ResourceAccess
    ](
        mut source: Self.Source, mut cache: ResourceDeviceCache
    ) raises -> Self.View[True]:
        """Zeroes or uploads device counts.

        Parameters:
            access: `WRITE` zeroes the counts; `READ_WRITE` uploads them.

        Args:
            source: Validated counts.
            cache: Leased cache on the world's device queue.

        Raises:
            Error: If allocation or upload fails.

        Returns:
            Writer view over device counts.
        """
        comptime if access.preserves_contents():
            return {
                cache.upload_mutable[UInt32](0, Span(source.counts)),
                source.shape,
            }
        else:
            return {
                cache.fill[UInt32](0, len(source.counts), 0),
                source.shape,
            }

    @staticmethod
    def stage_device_results[
        access: ResourceAccess
    ](mut source: Self.Source, mut cache: ResourceDeviceCache) raises:
        """Stages the counts for publication after completion.

        Parameters:
            access: `WRITE` or `READ_WRITE`.

        Args:
            source: Counts receiving outputs.
            cache: Cache holding this invocation's buffers.

        Raises:
            Error: If staging fails.
        """
        cache.download(0, Span(source.counts))


@fieldwise_init
struct ContactGridFill(TrivialRegisterPassable):
    """Writer view that scatters resting positions into their cell ranges."""

    var slots: Pointer[Position, MutUntrackedOrigin]
    var cursors: Pointer[UInt32, MutUntrackedOrigin]
    """Next free slot of each cell, starting at the cell's offset."""
    var shape: _GridShape

    @always_inline
    def add(self, position: Position, velocity: Velocity, deposit: Deposit):
        """Stores a particle's position in its cell if it is resting.

        Args:
            position: Wrapped particle position in meters.
            velocity: Particle velocity in meters per second.
            deposit: Particle's pile state.
        """
        if self.shape.resting(velocity, deposit):
            var slot = _increment(
                Pointer(
                    to=self.cursors[unsafe_offset=self.shape.cell(position)]
                )
            )
            # Metal can fail to compile a whole-Position store here.
            ref target = self.slots[unsafe_offset=slot]
            target.x = position.x
            target.y = position.y


@fieldwise_init
struct ContactResponse(Movable):
    """Displacement out of resting neighbors and how buried a particle is."""

    var push: Position
    """Displacement in meters."""
    var shelter: Float32
    """Fraction of the wind that the surrounding resting particles block."""
    var touching: Bool
    """Whether a resting particle is close enough to support this one."""


comptime _NEIGHBOR_RANGE: Float32 = 1.25
"""Resting particles closer than this many diameters support and shelter a
particle; grid cells are at least this wide."""
comptime _EXPOSED_NEIGHBORS: Float32 = 2
"""Sheltering neighbors that still leave a particle in the full wind."""
comptime _BURIED_NEIGHBORS: Float32 = 4
"""Sheltering neighbors that block the wind completely."""
comptime _MAX_CELL_READS = 24
"""Entries read per cell, which bounds the cost in overfilled cells."""


@fieldwise_init
struct ContactGridRead(TrivialRegisterPassable):
    """Read view that finds overlapping resting neighbors."""

    var slots: Pointer[Position, ImmUntrackedOrigin]
    var offsets: Pointer[UInt32, ImmUntrackedOrigin]
    """First slot of each cell, followed by the total slot count."""
    var shape: _GridShape

    @always_inline
    def respond(
        self, position: Position, bounds: Bounds, resting: Bool, seed: Int
    ) -> ContactResponse:
        """Returns the displacement that resolves this particle's share of
        each overlap with a resting particle, and its shelter.

        Two resting particles each move half of their overlap, so the pair
        separates without either one writing the other. A moving particle is
        not in the grid, so it takes the whole overlap and resting particles
        do not feel it. The displacement is capped at one radius, so dense
        clusters relax over several passes instead of exploding.

        Grid entries at exactly this position give no direction, and one of
        them is the particle itself if it is resting. If there are others,
        such as particles squeezed into the same inner corner of two
        obstacles, the particle moves in a direction derived from `seed`.

        Inside a pile the air is still: shelter grows from 0 with three
        resting neighbors within 1.25 diameters to 1 with four or more.

        Args:
            position: Wrapped particle position in meters.
            bounds: Periodic domain size.
            resting: Whether this particle is in the grid.
            seed: Value that differs between particles, such as the row.

        Returns:
            Displacement and shelter.
        """
        var shape = self.shape
        var diameter = 2 * shape.radius
        var cell = shape.cell(position)
        var column = cell % shape.columns
        var row = cell // shape.columns
        var share: Float32 = 0.5 if resting else 1
        var coincident = -1 if resting else 0
        var reach = _NEIGHBOR_RANGE * diameter
        var neighbors: Float32 = 0
        var touching = False
        var sx: Float32 = 0
        var sy: Float32 = 0
        comptime for oy in range(-1, 2):
            # Cells across the seam hold coordinates one domain away.
            var r = row + oy
            var y = position.y
            if r < 0:
                r += shape.rows
                y += bounds.height
            elif r >= shape.rows:
                r -= shape.rows
                y -= bounds.height
            comptime for ox in range(-1, 2):
                var c = column + ox
                var x = position.x
                if c < 0:
                    c += shape.columns
                    x += bounds.width
                elif c >= shape.columns:
                    c -= shape.columns
                    x -= bounds.width
                var neighbor_cell = r * shape.columns + c
                var start = Int(self.offsets[unsafe_offset=neighbor_cell])
                var end = min(
                    Int(self.offsets[unsafe_offset=neighbor_cell + 1]),
                    start + _MAX_CELL_READS,
                )
                for s in range(start, end):
                    ref other = self.slots[unsafe_offset=s]
                    var dx = x - other.x
                    var dy = y - other.y
                    var d2 = dx * dx + dy * dy
                    if d2 == 0:
                        coincident += 1
                        continue
                    if d2 >= reach * reach:
                        continue
                    neighbors += 1
                    touching = True
                    if d2 >= diameter * diameter:
                        continue
                    var distance = sqrt(d2)
                    var scale = share * (diameter - distance) / distance
                    sx += dx * scale
                    sy += dy * scale
        if coincident > 0:
            # Fibonacci hashing spreads neighboring seeds around the circle.
            # Integer math keeps the angle exact for large row indices.
            var hashed = UInt32(seed) * 2654435769
            var angle = 2 * pi * Float32(hashed >> 8) / 16777216
            sx += share * diameter * cos(angle)
            sy += share * diameter * sin(angle)
        var length2 = sx * sx + sy * sy
        if length2 > shape.radius * shape.radius:
            var limit = shape.radius / sqrt(length2)
            sx *= limit
            sy *= limit
        var shelter = (
            neighbors + Float32(max(coincident, 0))
        ) - _EXPOSED_NEIGHBORS
        shelter /= _BURIED_NEIGHBORS - _EXPOSED_NEIGHBORS
        return ContactResponse(
            Position(sx, sy),
            min(max(shelter, 0), 1),
            touching or coincident > 0,
        )


struct ContactGrid(DevicePassableResource):
    """Resting particle positions sorted by grid cell.

    Cells are at least 1.25 particle diameters wide, so all neighbors that
    overlap, support, or shelter a particle lie in its own or the eight
    adjacent cells.
    """

    comptime Adapter = ContactGridAdapter
    var shape: _GridShape
    var offsets: List[UInt32]
    """First slot of each cell, followed by the total slot count."""
    var slots: List[Position]
    var cursors: List[UInt32]
    """Scatter cursors; host-side scratch for writer views."""

    def __init__(
        out self,
        bounds: Bounds,
        *,
        radius: Float32 = 0.04,
        rest_speed: Float32 = 4,
        cell_size: Float32 = 0.2,
    ) raises:
        """Creates an empty grid that covers the domain.

        Args:
            bounds: Periodic domain size.
            radius: Contact radius of a particle in meters.
            rest_speed: Speed in meters per second below which a supported
                particle rests in the grid. Particles outside the grid
                bounce off resting ones but pass through each other.
            cell_size: Smallest cell edge in meters; at least 1.25
                particle diameters, the range of support and shelter.

        Raises:
            Error: If the cells are narrower than the neighbor range, or the
                domain spans fewer than three cells along an axis.
        """
        if radius <= 0 or cell_size < _NEIGHBOR_RANGE * 2 * radius:
            raise Error("Grid cells must span 1.25 particle diameters")
        var columns = Int(bounds.width / cell_size)
        var rows = Int(bounds.height / cell_size)
        if columns < 3 or rows < 3:
            raise Error("The domain must span at least three grid cells")
        self.shape = _GridShape(
            columns,
            rows,
            radius,
            rest_speed,
            Float32(columns) / bounds.width,
            Float32(rows) / bounds.height,
            bounds,
        )
        self.offsets = List[UInt32](length=columns * rows + 1, fill=0)
        self.slots = List[Position]()
        self.cursors = List[UInt32](length=columns * rows, fill=0)

    def total(self) -> Int:
        """Returns the number of resting particles in the grid.

        Returns:
            Total slot count.
        """
        return Int(self.offsets[self.shape.cells()])

    def set_counts(mut self, counts: ContactCounts):
        """Turns per-cell counts into cell offsets with a prefix sum.

        Args:
            counts: Resting particles per cell from `count_kernel`.
        """
        var running: UInt32 = 0
        for cell in range(self.shape.cells()):
            self.offsets[cell] = running
            running += counts.counts[cell]
        self.offsets[self.shape.cells()] = running
        if len(self.slots) < Int(running):
            self.slots.resize(Int(running), Position(0, 0))


struct ContactGridAdapter(ResourceAdapter):
    """Selects ContactGridRead for `read` and ContactGridFill otherwise.

    Transfers cover only the occupied slots.
    """

    comptime Source = ContactGrid
    comptime View[mutable: Bool] = (
        ContactGridFill if mutable else ContactGridRead
    )
    comptime supports_mutation = True
    # Slots are reserved atomically and written disjointly.
    comptime supports_concurrent_mutation = True

    @staticmethod
    def validate(source: Self.Source) raises:
        """Checks buffer sizes against the cell layout and slot count.

        Args:
            source: Current grid.

        Raises:
            Error: If buffers do not match the layout.
        """
        var cells = source.shape.cells()
        if (
            len(source.offsets) != cells + 1
            or len(source.cursors) != cells
            or len(source.slots) < source.total()
        ):
            raise Error("ContactGrid buffers do not match its cell layout")

    @staticmethod
    def bind_host(source: Self.Source) raises -> Self.View[False]:
        """Borrows host buffers for reading.

        Args:
            source: Validated grid.

        Raises:
            Error: Never.

        Returns:
            Read view over host buffers.
        """
        return {_imm(source.slots), _imm(source.offsets), source.shape}

    @staticmethod
    def prepare_device(
        source: Self.Source, mut cache: ResourceDeviceCache
    ) raises -> Self.View[False]:
        """Uploads offsets and occupied slots for a read view.

        Args:
            source: Validated grid.
            cache: Leased cache.

        Raises:
            Error: If an upload fails.

        Returns:
            Read view over device buffers.
        """
        return {
            cache.upload[Position](0, Span(source.slots)[: source.total()]),
            cache.upload[UInt32](1, Span(source.offsets)),
            source.shape,
        }

    @staticmethod
    def bind_host_mutable[
        access: ResourceAccess
    ](mut source: Self.Source) raises -> Self.View[True]:
        """Starts every cell's cursor at its offset, then borrows host buffers.

        Parameters:
            access: `WRITE` or `READ_WRITE`; both rebuild all slots.

        Args:
            source: Validated grid.

        Raises:
            Error: Never.

        Returns:
            Writer view over host buffers.
        """
        for cell in range(source.shape.cells()):
            source.cursors[cell] = source.offsets[cell]
        return {_mut(source.slots), _mut(source.cursors), source.shape}

    @staticmethod
    def prepare_device_mutable[
        access: ResourceAccess
    ](
        mut source: Self.Source, mut cache: ResourceDeviceCache
    ) raises -> Self.View[True]:
        """Uploads offsets as cursors and reserves the occupied slots.

        Parameters:
            access: `WRITE` or `READ_WRITE`; both rebuild all slots.

        Args:
            source: Validated grid.
            cache: Leased cache on the world's device queue.

        Raises:
            Error: If allocation or upload fails.

        Returns:
            Writer view over device buffers.
        """
        var cells = source.shape.cells()
        return {
            cache.upload_mutable[Position](
                0, Span(source.slots)[: source.total()]
            ),
            cache.upload_mutable[UInt32](2, Span(source.offsets)[:cells]),
            source.shape,
        }

    @staticmethod
    def stage_device_results[
        access: ResourceAccess
    ](mut source: Self.Source, mut cache: ResourceDeviceCache) raises:
        """Stages the occupied slots for publication after completion.

        Parameters:
            access: `WRITE` or `READ_WRITE`.

        Args:
            source: Grid receiving outputs.
            cache: Cache holding this invocation's buffers.

        Raises:
            Error: If staging fails.
        """
        cache.download(0, Span(source.slots)[: source.total()])
