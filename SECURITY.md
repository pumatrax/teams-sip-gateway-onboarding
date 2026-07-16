# Security Policy

This project handles provisioning files that may contain live SIP credentials and Microsoft onboarding session tokens.

Do not open a public issue containing:

- real MAC addresses;
- SIP usernames, authentication names, or passwords;
- complete onboarding or state URLs;
- phone numbers, display names, or tenant domains;
- packet captures, diagnostics bundles, or unredacted configuration files.

Before sharing examples, replace sensitive values with masks such as:

```text
<MAC12>
<MAC-COLON>
<OB-HASH>
<STATE-TOKEN>
<TEMP-PASSWORD>
<E164-NUMBER>
<TENANT-DOMAIN>
```
