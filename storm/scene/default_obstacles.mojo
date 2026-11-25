"""The default obstacle layout."""

from std.math import pi
from larecs import World
from storm.scene.obstacle_builder import ObstacleBuilder


def add_default_obstacles(mut world: World[...]) raises:
    """Spawns the default obstacles.

    Args:
        world: World that receives the obstacle entities.

    Raises:
        Error: If an obstacle cannot be spawned.
    """
    _ = ObstacleBuilder(30, 52).circle(0, 0, radius=6).spawn(world)
    _ = ObstacleBuilder(48, 66).circle(0, 0, radius=3.5).spawn(world)
    # A tilted barrier with round ends.
    _ = (
        ObstacleBuilder(62, 30, angle=0.35)
        .rectangle(0, 0, width=22, height=3)
        .circle(-11, 0, radius=2.5)
        .circle(11, 0, radius=2.5)
        .spawn(world)
    )
    # An L-shaped wall.
    _ = (
        ObstacleBuilder(96, 54, angle=-0.3)
        .rectangle(0, 0, width=16, height=2.5)
        .rectangle(-6.75, -5, width=2.5, height=10)
        .spawn(world)
    )
    # A diamond: a square rotated by 45 degrees.
    _ = (
        ObstacleBuilder(18, 20)
        .rectangle(0, 0, width=7, height=7, angle=Float32(pi / 4))
        .spawn(world)
    )
    # A cross with a round hub.
    _ = (
        ObstacleBuilder(86, 16, angle=0.2)
        .rectangle(0, 0, width=12, height=2)
        .rectangle(0, 0, width=2, height=12)
        .circle(0, 0, radius=2)
        .spawn(world)
    )
