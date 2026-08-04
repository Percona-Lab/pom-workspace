# Single-node Nomad (server + client in one agent) for local SEP development.
#
# Not `nomad agent -dev`: dev mode binds loopback-only and ignores most of this
# file, and we need the API reachable from the host (SEP runs natively) plus
# raw_exec explicitly enabled.

data_dir  = "/nomad/data"
bind_addr = "0.0.0.0"

# Quiet by default; raise to DEBUG when chasing a dispatch problem.
log_level = "INFO"

server {
  enabled          = true
  bootstrap_expect = 1
}

client {
  enabled = true

  node_class = "sep-executor"

  # Only raw_exec is ever used by SEP. Denylisting the rest keeps the client from
  # logging fingerprint errors for drivers with no runtime here (no Docker
  # socket, no QEMU, no JVM).
  options = {
    "driver.denylist" = "docker,exec,java,qemu"
  }
}

# SEP dispatches every job with the raw_exec driver, which Nomad disables unless
# explicitly enabled.
#
# Nomad 2.x removed the `no_cgroups` option this block used to need for
# containerised clients (it errors with "No argument or block type is named
# no_cgroups"), and the container runs privileged so it can manage its own
# cgroups instead.
plugin "raw_exec" {
  config {
    enabled = true
  }
}

telemetry {
  disable_hostname = true
}
