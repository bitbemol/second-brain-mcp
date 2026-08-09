## Engineering rules

- The developer owns architecture, product behavior, and scope.
- Investigate before modifying.
- Every bug fix begins with a failing reproduction.
- Implement only explicitly requested behavior.
- Do not fix additional findings.
- Do not add speculative edge-case handling.
- Do not refactor neighboring code during feature work.
- New abstractions and public behavior changes require approval.
- Prefer a known limitation over unrequested complexity.
- Stop if scope must expand or the approved design is insufficient.

## Verification

- Run focused tests after meaningful changes.
- Run the full suite before completion.
- Verify important behavior through the product boundary.
- Report what was and was not verified.