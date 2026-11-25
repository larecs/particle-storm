"""Helpers that populate a world with particles and obstacles."""

from .default_obstacles import add_default_obstacles
from .obstacle_builder import (
    ObstacleBuilder,
    next_obstacle_group,
    obstacle_contains,
)
from .particles import add_particles
