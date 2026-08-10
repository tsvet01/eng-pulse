# Week 12 — Ansible, and configuration as the source of truth

> **By the end:** you destroy a server and rebuild it to full service with one command — and
> you can state exactly what *isn't* captured in code.

**Time:** ≈6 h across 3 sessions · **Where:** Mac (control node) → both Hetzner boxes
**Prereq:** week 11 checkpoint. This week codifies everything from weeks 0–11.

---

## What this is, and why it matters

Everything you've built over eleven weeks exists as commands you typed once. That's the state
most infrastructure is actually in, and it's why "we're not sure what's on that box" is such a
common answer. This week converts it into code.

The concept that matters is **idempotence**: a playbook describes the *desired state*, and
running it moves the system toward that state. Running it again changes nothing. That's not a
convenience — it's what makes configuration a source of truth rather than a historical log.
A shell script says "I ran these steps once, on some machine, in some order." A playbook says
"this is what the machine *is*", and you can prove it by running it again and seeing zero
changes.

For where you're going, there's a second payoff. As a manager you've made claims about patch
state, compliance posture, and fleet consistency. Those claims are only defensible when the
configuration is code and the drift is measurable. `ansible-playbook --check --diff` against
production answers "are we actually configured the way we say we are?" — and that's a question
you'll be asked in audits.

### Why Ansible specifically

Agentless — it's SSH plus Python on the target, nothing to install or maintain. Puppet and
Chef, which you'd have known, required an agent and a server. Ansible's model won for server
configuration largely because it didn't. (Terraform occupies the adjacent space: Terraform
*provisions* infrastructure that doesn't exist yet; Ansible *configures* machines that do.
They compose.)

### The mental model

```
   inventory.yml        which machines, grouped, with variables
        │
   playbook.yml         which roles apply to which groups
        │
   roles/               reusable units of configuration
     └── common/
         ├── tasks/main.yml       what to do
         ├── handlers/main.yml    what to do on change (restart nginx)
         ├── templates/           Jinja2 files rendered with variables
         ├── files/               static files copied verbatim
         └── defaults/main.yml    overridable variables
```

---

## Session 1 — Inventory, ad-hoc, first playbook (≈1.5 h)

### Setup

Ansible runs from your Mac; the targets need only SSH and Python.

```bash
brew install ansible
ansible --version
```

`inventory.yml`:

```yaml
all:
  vars:
    ansible_user: anton
    ansible_ssh_common_args: '-o StrictHostKeyChecking=accept-new'
  children:
    web:
      hosts:
        rocky:
          ansible_host: <cx-public-ip>
    db:
      hosts:
        cax:
          ansible_host: 10.0.0.3
          ansible_ssh_common_args: '-o ProxyJump=anton@<cx-public-ip>'
```

Note the CAX inherits your week-4 topology — Ansible reaches it through the jump host, exactly
as your SSH config does.

```bash
ansible-inventory -i inventory.yml --graph
ansible all -i inventory.yml -m ping
```

### Ad-hoc commands

Useful before you write anything, and a good way to see modules work:

```bash
ansible all -i inventory.yml -m ping
ansible all -i inventory.yml -a "uptime"
ansible all -i inventory.yml -m setup | head -50          # every fact about a host
ansible all -i inventory.yml -m setup -a "filter=ansible_distribution*"
ansible web -i inventory.yml -m dnf -a "name=htop state=present" --become
```

`-m setup` dumps **facts** — the auto-discovered inventory of a machine (distribution, version,
interfaces, memory, mounts). You reference them in templates and conditionals as
`ansible_distribution`, `ansible_default_ipv4.address`, and so on.

### Your first playbook

`playbooks/base.yml`:

```yaml
- name: Base configuration
  hosts: all
  become: true
  tasks:
    - name: Install baseline packages
      ansible.builtin.dnf:
        name:
          - vim
          - htop
          - git
          - policycoreutils-python-utils
        state: present

    - name: Ensure dnf-automatic is enabled
      ansible.builtin.systemd_service:
        name: dnf-automatic.timer
        enabled: true
        state: started

    - name: Harden sshd
      ansible.builtin.lineinfile:
        path: /etc/ssh/sshd_config
        regexp: '^#?{{ item.key }}'
        line: "{{ item.key }} {{ item.value }}"
        validate: 'sshd -t -f %s'          # ← refuses to write a broken config
      loop:
        - { key: PermitRootLogin,        value: 'no' }
        - { key: PasswordAuthentication, value: 'no' }
      notify: restart sshd

  handlers:
    - name: restart sshd
      ansible.builtin.systemd_service:
        name: sshd
        state: restarted
```

```bash
ansible-playbook -i inventory.yml playbooks/base.yml --check --diff    # dry run FIRST
ansible-playbook -i inventory.yml playbooks/base.yml
ansible-playbook -i inventory.yml playbooks/base.yml                   # again: all "ok", zero "changed"
```

**That second run is the lesson.** Zero changed tasks means the playbook is genuinely
idempotent and the machine matches the code. If something reports "changed" every run, that
task is written imperatively and is lying to you about state.

Two details worth copying:

- **`validate:`** runs a syntax check before the file is put in place. On `sshd_config` this is
  the difference between a typo and losing access to the box.
- **Handlers** run once at the end, and only if something notified them. Restarting sshd on
  every run would be wrong; restarting it only when the config changed is right.

### Prove it

Run `base.yml` twice. Second run: all green, zero changed.

---

## Session 2 — Roles, templates, variables, secrets (≈1.5 h)

### Roles

Once a playbook has more than a dozen tasks, split it into roles.

```bash
mkdir -p roles/{common,web,monitoring}/{tasks,handlers,templates,files,defaults}
```

`roles/web/defaults/main.yml`:

```yaml
web_root: /srv/www
web_domain: app.example.com
web_port: 8080
```

`roles/web/tasks/main.yml`:

```yaml
- name: Install nginx
  ansible.builtin.dnf: { name: nginx, state: present }

- name: Create web root
  ansible.builtin.file:
    path: "{{ web_root }}"
    state: directory
    mode: '0755'

- name: Set the SELinux context for the web root
  community.general.sefcontext:
    target: "{{ web_root }}(/.*)?"
    setype: httpd_sys_content_t
    state: present
  notify: restore selinux context

- name: Allow nginx to make outbound connections
  ansible.posix.seboolean:
    name: httpd_can_network_connect
    state: true
    persistent: true

- name: Deploy the site config
  ansible.builtin.template:
    src: site.conf.j2
    dest: /etc/nginx/conf.d/{{ web_domain }}.conf
    validate: 'nginx -t -c /etc/nginx/nginx.conf'
  notify: reload nginx

- name: Open the firewall
  ansible.posix.firewalld:
    service: "{{ item }}"
    permanent: true
    immediate: true
    state: enabled
  loop: [http, https]

- name: Enable nginx
  ansible.builtin.systemd_service:
    name: nginx
    enabled: true
    state: started
```

Notice this role encodes weeks 5, 4, and 3 — SELinux contexts and booleans, firewalld
permanent+immediate, systemd enable+start. That's the week's real theme: everything you learned
by hand becomes a declarative statement.

`roles/web/handlers/main.yml`:

```yaml
- name: reload nginx
  ansible.builtin.systemd_service: { name: nginx, state: reloaded }

- name: restore selinux context
  ansible.builtin.command: restorecon -Rv {{ web_root }}
  changed_when: true
```

### Templates

Jinja2, rendered with your variables and the host's facts. `roles/web/templates/site.conf.j2`:

```nginx
# Managed by Ansible — local edits will be overwritten
server {
    listen 80;
    server_name {{ web_domain }};

    location / {
        proxy_pass http://127.0.0.1:{{ web_port }};
        proxy_set_header Host            $host;
        proxy_set_header X-Real-IP       $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

Always put that first comment line in generated files. Six months from now, someone (you) will
hand-edit it and wonder why the change vanished.

### Variable precedence

Roughly, low to high: role defaults → inventory group vars → inventory host vars → playbook
vars → `-e` on the command line. `defaults/` is for values you *expect* to be overridden;
`vars/` is for ones you don't.

```
group_vars/
  all.yml
  web.yml
host_vars/
  rocky.yml
```

### Secrets

```bash
ansible-vault create group_vars/all/vault.yml
ansible-vault edit group_vars/all/vault.yml
ansible-playbook -i inventory.yml site.yml --ask-vault-pass
```

Convention: put the encrypted value in `vault.yml` as `vault_db_password`, then reference it
from a plain variable file as `db_password: "{{ vault_db_password }}"`. That way the plain file
shows *which* secrets exist and where they're used — greppable — while the values stay
encrypted.

---

## Session 3 — Weekend block: rebuild from zero (≈3 h)

### The exercise

Write playbooks that take **both** Hetzner boxes from a bare OS image to their current state.
Then destroy one and prove it.

`site.yml`:

```yaml
- name: All hosts
  hosts: all
  become: true
  roles:
    - common          # users, ssh hardening, packages, dnf-automatic, journald persistence

- name: Web tier
  hosts: web
  become: true
  roles:
    - web             # nginx, SELinux contexts, firewalld, certbot
    - app             # the podman quadlet from week 9

- name: Monitoring
  hosts: all
  become: true
  roles:
    - monitoring      # node_exporter unit; prometheus on the web host
```

Everything from the plan, codified:

| Week | What the role must encode |
|---|---|
| 0 | Users, sudo, SSH keys, `PermitRootLogin no`, `PasswordAuthentication no`, dnf-automatic |
| 2 | The backup script, its dedicated user, directory permissions |
| 3 | `backup.service` + `backup.timer`, persistent journald, sandboxing directives |
| 4 | firewalld zones and services, private-network config |
| 5 | SELinux fcontexts and booleans, package set |
| 9 | The podman quadlet, `enable-linger`, nginx reverse proxy, certbot |
| 11 | node_exporter, Prometheus config, alert rules |

Useful modules for these: `ansible.builtin.template` (unit files), `ansible.builtin.systemd_service`,
`ansible.posix.seboolean`, `community.general.sefcontext`, `ansible.posix.firewalld`,
`ansible.builtin.user`, `containers.podman.podman_image`.

```bash
ansible-galaxy collection install ansible.posix community.general containers.podman
```

### The destructive test

This is the whole point of the week.

1. Snapshot the CAX (insurance only).
2. **Delete it.** Actually delete the server in the Hetzner console.
3. Create a new one from the base Rocky image, same private IP, same SSH key.
4. Update `inventory.yml` if the public IP changed.
5. `ansible-playbook -i inventory.yml site.yml`
6. Verify: services running, firewall correct, SELinux contexts right, metrics being scraped.

If that works, your infrastructure is code. If it doesn't, the gap you just found is the most
valuable output of the entire twelve weeks — because that gap exists in your production fleet
too, and nobody knows about it.

### Then write the gap list

The second half of the checkpoint, and the harder one. What is **not** captured in code?

Typically:

- DNS records (unless you manage them with Terraform)
- TLS certificates and their private keys — certbot re-obtains them, but that needs DNS to
  resolve first, so there's an ordering dependency
- Database *contents* — the schema might be in migrations; the data is in backups, and
  restoring it is a separate, untested procedure until you test it
- Anything set through a cloud console: firewalls, private networks, volumes, snapshots
- Vault passwords and any secret bootstrapping — the chicken-and-egg at the root of every
  secrets system
- SSH host keys — new ones mean every client sees a host-key warning
- Manual fixes applied during incidents and never codified. This is the big one, and it's the
  category that quietly grows.

That list **is** your risk register, and it's written in the language you've been reading risk
registers in for a decade. Put it in `notes.md`.

### Drift detection

Once you have this, you get a genuinely valuable operational capability for free:

```bash
ansible-playbook -i inventory.yml site.yml --check --diff
```

Any reported change is **drift** — the machine no longer matches the code. Run it weekly from
a timer and you can answer "are we configured the way we think we are?" with evidence rather
than belief. That question, asked about a hundred hosts, is most of what a compliance audit is.

---

## Command reference

```
ansible-inventory -i INV --graph            visualise groups and hosts
ansible all -i INV -m ping
ansible all -i INV -m setup                 all discovered facts
ansible GROUP -i INV -a "CMD" --become      ad-hoc shell
ansible-playbook -i INV PLAY.yml --check --diff     DRY RUN — always first
ansible-playbook -i INV PLAY.yml --limit HOST
ansible-playbook -i INV PLAY.yml --tags web
ansible-playbook -i INV PLAY.yml --start-at-task "NAME"
ansible-playbook -i INV PLAY.yml -vvv        debug: show the actual module calls
ansible-vault create|edit|view|rekey FILE
ansible-galaxy collection install NS.COLLECTION
ansible-lint PLAY.yml
```

---

## Traps

- **A task that reports "changed" on every run.** It's imperative, not declarative. Usually a
  `command`/`shell` task missing `creates:` or `changed_when:`.
- **`shell:` and `command:` everywhere.** If a module exists, use it — modules are idempotent
  and report state correctly. Shell tasks are an escape hatch, not a style.
- **No `validate:` on config templates.** A rendered typo plus a restart takes the service down
  across the whole group at once. Ansible's blast radius is the reason to be careful.
- **Secrets in plain YAML.** Vault them, and add `*vault*` awareness to your review habits.
- **Editing a managed file on the server.** Silently reverted next run. Hence the header comment.
- **Testing only on one host.** Run against the group; ordering and fact differences surface there.
- **Forgetting `--check --diff` before a real run** on anything you care about.

---

## Checkpoint

1. A **wiped server returns to full service from a single `ansible-playbook` run.**
2. Running the playbook a second time reports **zero changed tasks**.
3. You can state precisely what is *not* captured in code — and that list is written down.

---

## After week twelve

You're fluent. Where the next payoff is, roughly in order:

- **Kubernetes** — but only now. Having built containers, systemd units, and playbooks by hand,
  you'll read k8s as automation of things you understand rather than incantations.
- **Terraform** — the other half of infrastructure-as-code. Ansible configures machines that
  exist; Terraform creates them. Codify the Hetzner servers themselves and close the gap list.
- **Supply chain** — image signing, SBOMs, provenance. New since your era and squarely in the
  space you'll be asked to have an opinion on.
- **RHCSA objectives** — not the exam, the objective list, as an audit of your own gaps.
- **Deeper eBPF** — once `bpftrace` is comfortable it answers questions nothing else can.
- **Immutable systems** — Fedora CoreOS, bootc, NixOS. Credibly where servers are heading.

---

## If you want more

- Ansible docs: "Best Practices" and the module index (`ansible-doc -l`)
- `ansible-lint` — the ShellCheck of playbooks; run it in CI
- Molecule, for testing roles against throwaway containers
- *The Phoenix Project* / *Accelerate* — the management-side argument for why any of this
  matters, and useful vocabulary for making the case upward
