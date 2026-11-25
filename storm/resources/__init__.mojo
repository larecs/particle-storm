"""ECS resources: world-wide data that systems and kernels read."""

from .bounds import Bounds
from .contact_grid import ContactCounts, ContactGrid, ContactGridRead
from .editor import Editor
from .framebuffer import BACKGROUND, Framebuffer
from .input import Input
from .obstacles import MAX_OBSTACLES, Obstacles
from .physics import Physics
from .run_state import RunState
from .storm import Storm, Wind
from .time import Time
