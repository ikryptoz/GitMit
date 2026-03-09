# Security FAQ

## Is GitMit end-to-end encrypted?

GitMit is designed to encrypt message content end-to-end so plaintext is decrypted on client devices.

## Can the server read my messages?

Server infrastructure is intended to store encrypted message payloads and required metadata, not plaintext content.

## Does encryption hide everything?

No. Operational metadata (routing identifiers, timestamps, delivery state) is still required.

## How do I verify I am talking to the right person?

Use fingerprint verification with your peer over an out-of-band trusted channel.

## Can someone copy the app from GitHub?

If repository is public, source can be copied. This is true for any public repository.
Security depends on protecting secrets, backend authorization, and brand/package identity.

## Can web app code be fully hidden?

No. Browser clients must download executable assets. You can reduce abuse risk, but not fully hide client code.

## What should maintainers do to reduce theft/abuse risk?

- keep sensitive secrets out of git,
- move critical decisions to backend,
- use trademark/package controls,
- monitor and respond quickly to abuse.

## Where should I report security issues?

See `SECURITY.md` for responsible disclosure details.
