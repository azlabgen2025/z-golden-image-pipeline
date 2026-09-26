# `ansible/base/vars/`

## `golden_user.pub` (NOT committed)

The public key that gets baked into `ec2-user`'s `authorized_keys` in every
golden image this pipeline builds. Whoever holds the matching private key gets
passwordless `ec2-user` SSH (and therefore `sudo` root) on every image you
build. Treat it as a credential, not a config file.

It is generated for you by `scripts/setup-keys.sh` and is **git-ignored on
purpose** — do not commit it, and do not commit a real one to a public repo.

The private half is stored as the `GOLDEN_SSH_PRIVATE_KEY` GitHub Actions
secret. The GitHub workflow never reads this file: it derives the public key
from that secret with `ssh-keygen -y`, so the two can never drift apart.

The file only matters for **local** `packer build` runs, where the workflow is
not there to pass `-var golden_user_pub=...`.

## `golden_user.pub.example`

A deliberately useless placeholder so the file is never missing on a fresh
clone. It is a real RSA-2048 public key whose private half was generated in a
throwaway directory and destroyed immediately — nobody, including the project
maintainers, holds it. It grants access to nothing.

It exists so that:

- the Ansible playbooks can always resolve the path without erroring, and
- a fresh clone runs `packer validate` / `ansible --syntax-check` cleanly.

To use the placeholder instead of your own key, copy it:

```bash
cp ansible/base/vars/golden_user.pub.example ansible/base/vars/golden_user.pub
```

You will not be able to SSH to images built that way with it. Run
`scripts/setup-keys.sh` to generate a real pair instead.
