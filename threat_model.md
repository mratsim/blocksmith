# Threat model

1. Memory Exhaustion attacks
  - Forcing the Blocksmith to allocate more memory than possible on the system
2. Stack overflow
  - If recursive functions (or iterators/async) we can exhaust the stack
3. DOS
  - Fake blocks or attestations
  - Sync requests
  => The Rewinder service should collaborate with the PeerPool (which holds a rating) to drop bad peers.
  Note: if the peer generate a slashable event, maybe we keep it?
4. Collusion
  - Surrounding votes (https://github.com/protolambda/eth2-surround)
  - Eclipse attacks
