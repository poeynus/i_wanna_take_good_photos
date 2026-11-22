from math import isfinite

from pydantic import BaseModel, ConfigDict, Field, field_validator

CAPTURE_LIMITS = {
    "zoom": (1, 100),
    "exposureEv": (-12, 12),
    "iso": (1, 102400),
    "shutterSeconds": (0.00001, 120),
    "whiteBalanceKelvin": (1000, 20000),
}
COLOR_LIMITS = dict.fromkeys(
    ("brightness", "contrast", "saturation", "temperature", "highlights", "shadows"),
    (-1, 1),
)


class PresetBody(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True, strict=True)

    schemaVersion: int = Field(ge=1, le=1)
    name: str = Field(min_length=1, max_length=60)
    captureSettings: dict[str, float]
    colorSettings: dict[str, float]

    @field_validator("captureSettings", "colorSettings", mode="before")
    @classmethod
    def validate_settings(cls, value, info):
        limits = CAPTURE_LIMITS if info.field_name == "captureSettings" else COLOR_LIMITS
        if not isinstance(value, dict) or len(value) > len(limits):
            raise ValueError("Invalid settings")
        for key, number in value.items():
            if (key not in limits or type(number) not in (int, float)
                    or not limits[key][0] <= number <= limits[key][1]
                    or not isfinite(number)):
                raise ValueError(f"Invalid setting: {key}")
        return value


class PresetWrite(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    preset: PresetBody
    public: bool = False
