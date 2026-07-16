# Contributing

Thank you for helping improve this project.

## Before contributing

This workflow has only been tested with Yealink devices. Do not claim support for another manufacturer, model, or firmware without an end-to-end test.

Never commit or paste:

- real MAC addresses;
- SIP usernames, auth names, or passwords;
- complete Stage 2 or Stage 3 URLs;
- phone numbers, names, tenant domains, or verification codes;
- unredacted `.cfg`, `.env`, `.log`, `.pcap`, `.tar`, or diagnostics files.

Use placeholders such as `<MAC12>`, `<MAC-COLON>`, `<OB-HASH>`, `<STATE-TOKEN>`, `<TEMP-PASSWORD>`, `<E164-NUMBER>`, and `<TENANT-DOMAIN>`.

## Bug reports

Include the OS, Bash version, masked device identity, exact sanitized command, stage where the problem occurred, HTTP status codes, expected behavior, actual behavior, and a sanitized log excerpt.

## Development checks

```bash
bash -n teams_onboarding_flow.sh
git diff --check
git status
```

Search for sensitive patterns:

```bash
grep -RInE   'account\.[0-9]+\.password|device/state/OnBoarding/mmiiaacc/[A-Za-z0-9]+'   --exclude-dir=.git   .
```

Review all matches manually.

## Pull requests

Keep pull requests focused. Explain what changed, why, and how it was tested. Update the README and guide when behavior changes.
