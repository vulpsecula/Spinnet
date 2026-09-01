# Prioritize cold invocation within a low memory footprint

Spinnet will minimize steady-state memory only after meeting its menu-open and cold Action invocation targets. Installed but idle Plugins must not require resident processes, opening a Menu must not start a Plugin runtime, and helpers should return to the native Host baseline after inactivity; exact latency and private-memory budgets will be accepted from prototype measurements rather than assumed in advance.
