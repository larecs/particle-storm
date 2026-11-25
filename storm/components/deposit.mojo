"""Pile state of a particle component."""


@fieldwise_init
struct Deposit(TrivialRegisterPassable):
    """Whether a particle rests in a pile, and how much the pile shelters it.

    A particle is supported when it is slow and touches an obstacle or a
    supported particle, so piles grow outward from obstacle surfaces.
    """

    var support: Float32
    """1 if the particle is supported, otherwise 0. A float, since a Bool
    field here trips an arm64 LLVM backend crash ("Incomplete scavenging")
    in the threaded movement kernel."""
    var shelter: Float32
    """Fraction of the wind that supported neighbors block, from 0 to 1."""
    var sleep: Float32
    """Contact passes this buried particle stays frozen and skips all forces
    and neighbor searches. It stays in the grid, so others still collide
    with it."""

    comptime AIRBORNE = Self(support=0, shelter=0, sleep=0)

    @staticmethod
    def resting(supported: Bool, shelter: Float32) -> Self:
        """Creates a pile state.

        Args:
            supported: Whether the particle rests on an obstacle or pile.
            shelter: Fraction of the wind that supported neighbors block.

        Returns:
            The pile state.
        """
        return Self(Float32(1) if supported else 0, shelter, 0)

    def supported(self) -> Bool:
        """Returns whether the particle rests on an obstacle or pile.

        Returns:
            True if the particle is supported.
        """
        return self.support > 0

    @always_inline
    def sleeping(self) -> Bool:
        """Returns whether the particle is frozen inside a pile.

        Returns:
            True if contact passes remain before the particle wakes.
        """
        return self.sleep > 0
