
<p align="center">
  <img src="assets/teams-logo.png" alt="Microsoft Teams" height="110">
  &nbsp;&nbsp;&nbsp;&nbsp;
  <img src="assets/yealink-logo.png" alt="Yealink" height="80">
</p>

<h1 align="center">
  Manual Microsoft Teams SIP Gateway Onboarding for Yealink Devices
</h1>

# Manual Microsoft Teams SIP Gateway Onboarding for Yealink Devices

This repository documents and automates a tested manual onboarding workflow for certain **Yealink SIP phones** that cannot complete Microsoft Teams SIP Gateway onboarding with their native provisioning or SIP identity.

> **Tested scope:** Yealink devices only. This is not a universal SIP-device onboarding method.

## What this workflow does

The Microsoft provisioning flow is staged:

1. **Stage 1** starts at the fixed Microsoft provisioning endpoint.
2. Stage 1 returns a URL for **Stage 2**.
3. Stage 2 creates temporary onboarding SIP credentials and returns a unique **Stage 3 state URL**.
4. The device is verified by dialing `*55*<verification-code>`.
5. Teams sign-in is completed in a **computer web browser**.
6. The exact Stage 3 URL from the original Stage 2 session is polled until it returns the final user configuration.

The key rule is:

> Do not rerun Stage 1 or Stage 2 after verification starts. Stage 2 can mint a new onboarding token and new temporary credentials, which breaks the association with the session already verified in Teams Admin Center.

## Why the custom User-Agent matters

There are two separate User-Agent requirements:

- The `curl` requests need a supported Yealink-style HTTP User-Agent.
- The phone should be primed from a TFT/TFTP-hosted `-all.cfg` with an Account 1 custom SIP User-Agent before the Microsoft-generated account is added.

Example priming setting:

```cfg
account.1.custom_ua = Yealink SIP-<MODEL> <FIRMWARE> <MAC12>
```

This is crucial because successful config download alone does not guarantee that the phone's SIP REGISTER traffic will be accepted or shown online.

## MAC formats

Use the MAC without separators in filenames:

```text
805eXXXXdc69.cfg
```

Use the colon-formatted MAC in the HTTP User-Agent:

```text
80:5e:XX:XX:dc:69
```

Example HTTP User-Agent:

```text
Yealink SIP-T57W 96.86.5.1 80:5e:XX:XX:dc:69
```

## URL patterns

Stage 1:

```text
http://noam.ipp.sdg.teams.microsoft.com/<MAC12>.cfg
```

Stage 2:

```text
https://usea.dm.sdg.teams.microsoft.com/device/ob/<OB-HASH>/lang_en/<MAC12>.cfg
```

Stage 3 onboarding state:

```text
https://usea.dm.sdg.teams.microsoft.com/device/state/OnBoarding/mmiiaacc/<STATE-TOKEN>/lang_en/<MAC12>.cfg
```

Final persistent device path:

```text
https://usea.dm.sdg.teams.microsoft.com/device/mmiiaacc/<STATE-TOKEN>/lang_en/<MAC12>.cfg
```

## Running the interactive script

```bash
chmod +x teams_onboarding_flow.sh
./teams_onboarding_flow.sh <MAC12> <MODEL> <FIRMWARE>
```

Example:

```bash
./teams_onboarding_flow.sh 805eXXXXdc69 T57W 96.86.5.1
```

The script:

- downloads Stage 1 once;
- pauses for Stage 1 upload/application;
- downloads Stage 2 once;
- preserves the exact Stage 3 URL;
- pauses for Stage 2 upload and reboot;
- prompts for the TAC verification code;
- displays `*55*<code>`;
- pauses for browser sign-in;
- polls the same Stage 3 URL;
- saves the changed final configuration when detected.

## Output

Each run creates a timestamped directory:

```text
<MAC12>-onboarding-YYYYMMDD-HHMMSS/
```

It may contain:

```text
<MAC12>-stage1.cfg
<MAC12>-stage2.cfg
<MAC12>-stage3-attempt1.cfg
<MAC12>-stage3-final.cfg
session.env
workflow.log
```

## Security

Generated configurations may contain:

- SIP usernames
- authentication names
- passwords
- tenant domains
- phone numbers
- display names
- onboarding session tokens

Do not commit generated `.cfg` files, `session.env`, workflow logs, packet captures, diagnostics archives, or real MAC addresses.

See the included Word guide for the full procedure and troubleshooting notes.

## Current test status

The control flow and staged retrieval have been tested. A complete final validation should be performed with a real lab Yealink phone because the `*55*<verification-code>` step requires an actual temporary SIP account registered on a device.
