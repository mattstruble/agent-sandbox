# Changelog

## 1.0.0 (2026-04-25)


### Features

* **ci:** publish release tarball to GitHub Releases ([8d489ba](https://github.com/mattstruble/agent-sandbox/commit/8d489ba6a063c27fa7969e360e06999cfcc5bd9c))
* **config:** add follow_symlinks option for safe symlink mounting ([3ed20ce](https://github.com/mattstruble/agent-sandbox/commit/3ed20ce0b30a9ebb9bea29cada5c16dc2b6a2ed2))
* **deps:** add Renovate config for automated dependency updates ([e2e44d9](https://github.com/mattstruble/agent-sandbox/commit/e2e44d9140a96588f7cfd4d6698d1b81261cc41f))
* **entrypoint:** add container entrypoint with config staging and permission overrides ([c97a0e5](https://github.com/mattstruble/agent-sandbox/commit/c97a0e521bb58d0d6c9b4b0602646f381c663f9f))
* **firewall:** add iptables network allowlist with DNS pinning and IP range fetching ([ae3f287](https://github.com/mattstruble/agent-sandbox/commit/ae3f2870245e25e8999eb0b9e907dfa1c71f2e73))
* **image:** add Containerfile with pinned tool versions and SHA256 verification ([1396c87](https://github.com/mattstruble/agent-sandbox/commit/1396c8756d271f9d13780361df9826312d68a559))
* **install:** add curl|sh installer for non-Nix users ([e8d7bab](https://github.com/mattstruble/agent-sandbox/commit/e8d7bab50fc771e9c6250b170cc87b5299b5203f))
* **launcher:** add --update flag for self-updating ([6e9fe0b](https://github.com/mattstruble/agent-sandbox/commit/6e9fe0b412a9ab3847d6422aa39b216c679ca38c))
* **launcher:** add --version flag with build-time version substitution ([b1834b9](https://github.com/mattstruble/agent-sandbox/commit/b1834b9d4875b1a44afc66c44866029ec468f842))
* **launcher:** add agent-sandbox CLI with lifecycle, isolation, and configuration management ([af3d7a4](https://github.com/mattstruble/agent-sandbox/commit/af3d7a489aafcf23eccd2256d198bf4b278ac795))
* **launcher:** make launcher portable to bash 3.2+ without GNU deps ([1a73b79](https://github.com/mattstruble/agent-sandbox/commit/1a73b797e3dc5ae66dc38df2931906bc8f3b64fe))
* nix container ([#7](https://github.com/mattstruble/agent-sandbox/issues/7)) ([64a951f](https://github.com/mattstruble/agent-sandbox/commit/64a951fe8096776e10bb553231a02570d221a9e8))
* **nix:** add flake.nix with multi-platform packaging and runtime dependencies ([1a360d9](https://github.com/mattstruble/agent-sandbox/commit/1a360d9b8db352b6af7aad796c3a5980a4643dfb))
* **nix:** add NixOS, nix-darwin, and Home Manager modules ([94e6c14](https://github.com/mattstruble/agent-sandbox/commit/94e6c147ce652d98433a20d78f336a528d92192b))
* **nix:** migrate flake to flake-parts with version substitution and module exports ([060b539](https://github.com/mattstruble/agent-sandbox/commit/060b5397ce060b792e2a572eccfc9218e8fdda83))


### Bug Fixes

* **launcher:** add SETUID/SETGID caps, no-new-privileges, and normalize SSH_AUTH_SOCK ([5440011](https://github.com/mattstruble/agent-sandbox/commit/5440011737f2b231e6edd34e34caf662e980d9a2))
* **launcher:** resolve staging dir symlinks for Podman virtiofs on macOS ([4e682f2](https://github.com/mattstruble/agent-sandbox/commit/4e682f29402f1bfa70b7d93443b4e4a3923fb576))
* opencode permissions ([#8](https://github.com/mattstruble/agent-sandbox/issues/8)) ([bb7a1c1](https://github.com/mattstruble/agent-sandbox/commit/bb7a1c163276e8ec1e1ccf21470ccd0846e8caef))
* opencode timeout ([#1](https://github.com/mattstruble/agent-sandbox/issues/1)) ([d2c26c2](https://github.com/mattstruble/agent-sandbox/commit/d2c26c297d36cf8ef21e69570f23c58a4436ce4e))
* **security:** harden sandbox with port-based firewall and staging fixes ([4987753](https://github.com/mattstruble/agent-sandbox/commit/49877539249cacb6f9a30c8a01f5abefc138b667))
* stage conifg under HOME ([cdc5092](https://github.com/mattstruble/agent-sandbox/commit/cdc509202b16ec5e37a57050e8329fb3877cd4e3))
