//// Angle unit conventions for DH. Humans author angles in DEGREES — JSON
//// config fields (e.g. a hull's `dock_port_orientation`) and the named
//// defaults below read as 0/90/180/270, not opaque radian literals. The sim
//// math (headings, `cos`/`sin`, orbit rails) runs in RADIANS. Convert once, at
//// the boundary where an authored degree value enters the math, with
//// `deg_to_rad`; go the other way for display with `rad_to_deg`.

pub const pi = 3.141592653589793

/// Degrees -> radians. Use at decode / geometry sites to lift an authored
/// (degree) angle into the radian frame the sim computes in.
pub fn deg_to_rad(deg: Float) -> Float {
  deg *. pi /. 180.0
}

/// Radians -> degrees. The inverse, for surfacing a computed angle to a human.
pub fn rad_to_deg(rad: Float) -> Float {
  rad *. 180.0 /. pi
}
