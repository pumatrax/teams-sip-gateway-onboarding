# Security Policy

Generated provisioning files can contain live SIP usernames, authentication names, passwords, phone numbers, tenant domains, and Microsoft onboarding state tokens.

Do not publish:

- real MAC addresses;
- full Stage 2 or Stage 3 URLs;
- SIP credentials;
- unredacted configuration files;
- packet captures or diagnostics bundles;
- user names, phone numbers, or tenant information.

Use placeholders such as:

```text
<MAC12>
<MAC-COLON>
<OB-HASH>
<STATE-TOKEN>
<TEMP-PASSWORD>
<E164-NUMBER>
<TENANT-DOMAIN>
```
