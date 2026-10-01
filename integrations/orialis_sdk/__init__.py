"""Small, transport-neutral Orialis multi-device client scaffold."""

from .multidevice import (
    CapabilityDecision,
    ContractError,
    MultiDeviceClient,
    MultiDeviceMcpAdapter,
)

__all__ = [
    "CapabilityDecision",
    "ContractError",
    "MultiDeviceClient",
    "MultiDeviceMcpAdapter",
]
