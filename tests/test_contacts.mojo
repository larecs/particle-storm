"""Checks particle-particle contacts on the threaded host and a device."""

from std.math import cos, sin, sqrt
from std.sys import has_accelerator
from std.testing import (
    assert_almost_equal,
    assert_equal,
    assert_false,
    assert_true,
)
from larecs import ExecutionBackend, Filter, SystemContext, World
from storm.components import Deposit, Obstacle, Position, Velocity
from storm.periodic import wrap_delta
from storm.resources import Bounds, ContactGrid, Obstacles
from storm.systems import ContactSystem


# SKIP_DEBUG


comptime RADIUS: Float32 = 0.04
comptime SUPPORTED = Deposit(support=1, shelter=0, sleep=0)


def closest_pair(
    mut world: World[Position, Velocity, Deposit], bounds: Bounds
) raises -> Float32:
    """Returns the smallest periodic distance between supported particles.

    Args:
        world: World whose entities all are particles.
        bounds: Periodic domain size.

    Raises:
        Error: If the query fails.

    Returns:
        Smallest pairwise distance in meters.
    """
    var positions = List[Position]()
    for entity in world.storage.query[Filter().read[Position, Deposit]()]():
        if entity.get[Deposit]().supported():
            positions.append(entity.get[Position]())
    var closest = Float32(1e9)
    for i in range(len(positions)):
        for j in range(i + 1, len(positions)):
            var dx = wrap_delta(positions[i].x - positions[j].x, bounds.width)
            var dy = wrap_delta(positions[i].y - positions[j].y, bounds.height)
            closest = min(closest, sqrt(dx * dx + dy * dy))
    return closest


def count_at(
    mut world: World[Position, Velocity, Deposit], point: Position
) raises -> Int:
    """Counts particles exactly at a point.

    Args:
        world: World whose entities all are particles.
        point: Position to match.

    Raises:
        Error: If the query fails.

    Returns:
        Number of particles at the point.
    """
    var count = 0
    for entity in world.storage.query[Filter().read[Position]()]():
        var p = entity.get[Position]()
        if p.x == point.x and p.y == point.y:
            count += 1
    return count


def max_shelter(
    mut world: World[Position, Velocity, Deposit]
) raises -> Float32:
    """Returns the largest shelter of any particle.

    Args:
        world: World whose entities all are particles.

    Raises:
        Error: If the query fails.

    Returns:
        Largest shelter fraction.
    """
    var largest: Float32 = 0
    for entity in world.storage.query[Filter().read[Deposit]()]():
        largest = max(largest, entity.get[Deposit]().shelter)
    return largest


def count_asleep(mut world: World[Position, Velocity, Deposit]) raises -> Int:
    """Counts particles sleeping inside a pile.

    Args:
        world: World whose entities all are particles.

    Raises:
        Error: If the query fails.

    Returns:
        Number of sleeping particles.
    """
    var count = 0
    for entity in world.storage.query[Filter().read[Deposit]()]():
        if entity.get[Deposit]().sleeping():
            count += 1
    return count


def check_backend[backend: ExecutionBackend]() raises:
    """Separates a pair, a pair across the seam, and a dense cluster.

    Parameters:
        backend: Execution backend for the contact kernels.

    Raises:
        Error: If a check fails.
    """
    var bounds = Bounds()
    var world = World[Position, Velocity, Deposit]()
    world.resources.add(bounds)
    var obstacles = Obstacles()
    obstacles.add(Position(30, 30), Obstacle.circle(1))
    world.resources.add(obstacles)
    world.resources.add(ContactGrid(bounds, radius=RADIUS))
    var a = world.storage.add_entity(
        Position(10, 10), Velocity(1, 0), SUPPORTED
    )
    var b = world.storage.add_entity(
        Position(10.04, 10), Velocity(0, 0), SUPPORTED
    )
    # Overlapping across the vertical seam.
    var c = world.storage.add_entity(
        Position(0.01, 50), Velocity(0, 0), SUPPORTED
    )
    var d = world.storage.add_entity(
        Position(119.98, 50), Velocity(0, 0), SUPPORTED
    )
    # Airborne particles: one next to the obstacle, and a pair in open air.
    var e = world.storage.add_entity(
        Position(30, 31.02), Velocity(0, 0), Deposit.AIRBORNE
    )
    var f = world.storage.add_entity(
        Position(50, 50), Velocity(0, 0), Deposit.AIRBORNE
    )
    var g = world.storage.add_entity(
        Position(50.05, 50), Velocity(0, 0), Deposit.AIRBORNE
    )
    var context = SystemContext(world)
    var system = ContactSystem[backend](passes=1)
    system.initialize(context)
    system.update(context)

    # Each partner moves half of the 0.04 m overlap and loses the velocity
    # that drives it into the other.
    ref storage = context.world[].storage
    assert_almost_equal(storage.get[Position](a).x, 9.98, atol=1e-4)
    assert_almost_equal(storage.get[Position](b).x, 10.06, atol=1e-4)
    assert_equal(storage.get[Velocity](a).dx, 0)
    var right = storage.get[Position](c).x
    var left = storage.get[Position](d).x
    var seam = wrap_delta(right - left, bounds.width)
    assert_almost_equal(seam, 2 * RADIUS, atol=1e-4)
    assert_true(left < bounds.width)
    # A slow particle at an obstacle becomes supported; airborne particles
    # pass through each other.
    assert_true(storage.get[Deposit](e).supported())
    assert_false(storage.get[Deposit](f).supported())
    assert_false(storage.get[Deposit](g).supported())
    assert_equal(storage.get[Position](g).x, 50.05)
    # A lone pair is fully exposed to the wind.
    assert_equal(storage.get[Deposit](a).shelter, 0)

    # Particles stacked on one point split up.
    for _ in range(3):
        _ = storage.add_entity(Position(70, 20), Velocity(0, 0), SUPPORTED)
    system.update(context)
    assert_true(count_at(context.world[], Position(70, 20)) <= 1)

    # A dense cluster pressed against an obstacle relaxes to resting contact
    # without entering the obstacle.
    for i in range(300):
        var angle = Float32(i) * 2.39996
        var r = 1.0 + 0.35 * sqrt(Float32(i) / 300)
        _ = storage.add_entity(
            Position(
                30 + r * Float32(cos(angle)), 30 + r * Float32(sin(angle))
            ),
            Velocity(0, 0),
            SUPPORTED,
        )
    for _ in range(100):
        system.update(context)
    assert_true(closest_pair(context.world[], bounds) > 1.9 * RADIUS)
    for entity in storage.query[Filter().read[Position]()]():
        var p = entity.get[Position]()
        var dx = p.x - 30
        var dy = p.y - 30
        assert_true(dx * dx + dy * dy >= 0.999)
    # Particles inside the packed ring are sheltered from the wind.
    assert_equal(max_shelter(context.world[]), 1)
    # Settled, buried particles sleep.
    assert_true(count_asleep(context.world[]) > 0)
    # The ring stays supported by the obstacle and its neighbors.
    assert_true(context.world[].resources.read[ContactGrid]().total() >= 290)


def main() raises:
    """Runs the contact checks on the host and, if available, a device.

    Raises:
        Error: If a check fails.
    """
    check_backend[ExecutionBackend.HOST_THREADED]()
    comptime if has_accelerator():
        check_backend[ExecutionBackend.DEVICE]()
    print("PASS: pair, seam, support, stacked points, shelter, cluster, sleep")
