# VPN Failover recovery development

Development **0.3.0-dev.3** adds independent AWG probing and bounded runtime recovery for Podkop, Forkop and Forkozz/NetShift. Version 0.2.1 does not contain this fix.

Pause Failover before stopping the routing backend for maintenance. `pause` persists; `resume` only clears it. Active, unpaused Failover can start a stopped backend/sing-box, without changing their boot enablement. `status`/`dashboard` and opening LuCI are read-only and never probe the network.

Configure an explicit per-section `vpn_failover.main.interfaces` allowlist. Missing allowlist permits same-tunnel engine recovery only. Auto detection uses live service/nft evidence; ambiguous or unsupported configurations fail closed. Arbitrary AWG names are supported. Other sections, AWG profiles, DNS, Tailscale and SSH are preserved.

Recovery verifies the actual running engine's named section path using an existing exclusively bound loopback mixed inbound or its existing local Clash API. No test ports are opened. Unsupported path verification reports `PATH_TEST_UNAVAILABLE`, never success. Native backend generation must precede any fallback engine start. The OpenWrt sing-box init contract is checked before fallback.

Installer preserves existing configuration, daemon running state and enablement. This development code is published in the repository; no tagged release has been created; one authorized OpenWrt 25.12.5 / Forkozz stand was installed and tested. Local mocked tests are separate from hardware acceptance. See [Russian instructions](README.md), [recovery contract and pilot protocol](RECOVERY.md), and [validation](VALIDATION.md).
