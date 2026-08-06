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

  # This workstation's disk sits at ~81% used, just over Nomad's default
  # gc_disk_usage_threshold of 80. Over the threshold the client garbage
  # collects a terminal allocation within the same second it completes, taking
  # the alloc directory and its logs with it. SEP then fetches the logs it was
  # told to expect, Nomad answers "state for allocation ... not found on
  # client", and /api/tasks/history/{id}/sync/ turns that into a 500 — surfacing
  # as "an unexpected error occurred on the server" for a task that in fact
  # succeeded. Raised so completed allocations survive long enough to be read.
  gc_disk_usage_threshold  = 95
  gc_inode_usage_threshold = 95

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
