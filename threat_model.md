# Threat model

1. Memory Exhaustion attacks
  -> Forcing the Blocksmith to allocate more memory than possible on the system
2. Stack overflow
  -> If recursive functions (or iterators/async) we can exhaust the stack
3. DOS
  -> Fake blocks or attestations
  -> Sync requests
