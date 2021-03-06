#!/usr/bin/env ruby
#    This file is part of Metasm, the Ruby assembly manipulation suite
#    Copyright (C) 2006-2009 Yoann GUILLOT
#
#    Licence is LGPL, see LICENCE in the top-level directory


#
# this script disassembles an executable (elf/pe) using the GTK front-end
# use live:bla to open a running process whose filename contains 'bla'
#
# key binding (non exhaustive):
#  Enter to follow a label (the current hilighted word)
#  Esc to return to the previous position
#  Space to switch between listing and graph views
#  Tab to decompile (on already disassembled code)
#  'c' to start disassembling from the cursor position
#  'g' to go to a specific address (label/042h)
#  'l' to list known labels
#  'f' to list known functions
#  'x' to list xrefs to current address
#  'n' to rename a label (current word or current address)
#  ctrl+'r' to run arbitrary ruby code in the context of the Gui objet (access to 'dasm', 'curaddr')
#  ctrl+mousewheel to zoom in graph view ; also doubleclick on the background ('fit to window'/'reset zoom')
#

require 'metasm'
include Metasm
require 'optparse'

$VERBOSE = true

# parse arguments
opts = {}
OptionParser.new { |opt|
	opt.banner = 'Usage: disassemble-gtk.rb [options] <executable> [<entrypoints>]'
	opt.on('--no-data-trace', 'do not backtrace memory read/write accesses') { opts[:nodatatrace] = true }
	opt.on('--debug-backtrace', 'enable backtrace-related debug messages (very verbose)') { opts[:debugbacktrace] = true }
	opt.on('-P <plugin>', '--plugin <plugin>', 'load a metasm disassembler/debugger plugin') { |h| (opts[:plugin] ||= []) << h }
	opt.on('-e <code>', '--eval <code>', 'eval a ruby code') { |h| (opts[:hookstr] ||= []) << h }
	opt.on('--map <mapfile>', 'load a map file (addr <-> name association)') { |f| opts[:map] = f }
	opt.on('--fast', 'dasm cli args with disassemble_fast_deep') { opts[:fast] = true }
	opt.on('--decompile') { opts[:decompile] = true }
	opt.on('--gui <gtk|win32|qt>') { |g| ENV['METASM_GUI'] = g }
	opt.on('--cpu <cpu>', 'the CPU class to use for a shellcode (Ia32, X64, ...)') { |c| opts[:sc_cpu] = c }
	opt.on('--exe <exe_fmt>', 'the executable file format to use (PE, ELF, ...)') { |c| opts[:exe_fmt] = c }
	opt.on('--rebase <addr>', 'rebase the loaded file to <addr>') { |a| opts[:rebase] = Integer(a) }
	opt.on('-c <header>', '--c-header <header>', 'read C function prototypes (for external library functions)') { |h| opts[:cheader] = h }
	opt.on('-a', '--autoload', 'loads all relevant files with same filename (.h, .map..)') { opts[:autoload] = true }
	opt.on('-v', '--verbose') { $VERBOSE = true }	# default
	opt.on('-q', '--no-verbose') { $VERBOSE = false }
	opt.on('-d', '--debug') { $DEBUG = $VERBOSE = true }
	opt.on('-S <file>', '--session <sessionfile>', 'save user actions in this session file') { |a|  opts[:session] = a }
	opt.on('-N', '--new-session', 'start new session, discard old one') { opts[:newsession] = true }
	opt.on('-A', '--disassemble-all-entrypoints') { opts[:dasm_all] = true }
}.parse!(ARGV)

opts[:sc_cpu] = eval(opts[:sc_cpu]) if opts[:sc_cpu] =~ /[.(\s:]/
opts[:sc_cpu] = Metasm.const_get(opts[:sc_cpu]) if opts[:sc_cpu].kind_of?(::String)
opts[:sc_cpu] = opts[:sc_cpu].new if opts[:sc_cpu].kind_of?(::Class)
opts[:exe_fmt] = eval(opts[:exe_fmt]) if opts[:exe_fmt] =~ /[.(\s:]/

case exename = ARGV.shift
when /^live:(.*)/
	t = $1
	t = t.to_i if $1 =~ /^[0-9]+$/
	os = OS.current
	raise 'no such target' if not target = os.find_process(t) || os.create_process(t)
	p target if $VERBOSE
	w = Gui::DbgWindow.new(target.debugger, "#{target.pid}:#{target.modules[0].path rescue nil} - metasm debugger")
	dbg = w.dbg_widget.dbg
when /^emu:(.*)/
	t = $1
	exefmt = opts[:exe_fmt] || AutoExe.orshellcode { opts[:sc_cpu] || Ia32.new }
	dbgexe = exefmt.decode_file(t)
	dbgexe.cpu = opts[:sc_cpu] if opts[:sc_cpu]
	dbg = EmuDebugger.new(dbgexe.disassembler)
	w = Gui::DbgWindow.new(dbg, "emudbg")
when /^(tcp:|udp:)?..+:/
	dbg = GdbRemoteDebugger.new(exename, opts[:sc_cpu] || Ia32.new)
	w = Gui::DbgWindow.new(dbg, "remote - metasm debugger")
else
	w = Gui::DasmWindow.new("#{exename + ' - ' if exename}metasm disassembler")
	if exename
		exe = w.loadfile(exename, opts[:sc_cpu] || 'Ia32', opts[:exe_fmt])
		exe.disassembler.cpu = exe.cpu = opts[:sc_cpu] if opts[:sc_cpu]
		exe.disassembler.rebase(opts[:rebase]) if opts[:rebase]
		if opts[:autoload]
			basename = exename.sub(/\.\w\w?\w?$/, '')
			opts[:map] ||= basename + '.map' if File.exist?(basename + '.map')
			opts[:cheader] ||= basename + '.h' if File.exist?(basename + '.h')
			(opts[:plugin] ||= []) << (basename + '.rb') if File.exist?(basename + '.rb')
			opts[:session] ||= basename + '.metasm-session' if File.exist?(basename + '.metasm-session')
		end
	end
end

ep = ARGV.map { |arg| (?0..?9).include?(arg[0]) ? Integer(arg) : arg }
ep += exe.get_default_entrypoints if opts[:dasm_all]

if exe
	dasm = exe.disassembler

	dasm.load_map opts[:map] if opts[:map]
	dasm.parse_c_file opts[:cheader] if opts[:cheader]
	dasm.backtrace_maxblocks_data = -1 if opts[:nodatatrace]
	dasm.debug_backtrace = true if opts[:debugbacktrace]
	dasm.callback_finished = lambda { dasm.callback_finished = nil ; w.dasm_widget.focus_addr w.dasm_widget.curaddr, :decompile ; dasm.decompiler.finalize } if opts[:decompile]
elsif dbg
	dbg.load_map opts[:map] if opts[:map]
	dbg.disassembler.parse_c_file opts[:cheader] if opts[:cheader]
	opts[:plugin].to_a.each { |p|
		begin
			dbg.load_plugin(p)
		rescue ::Exception
			puts "Error with plugin #{p}: #{$!.class} #{$!}"
		end
	}
	if exename[0, 4] == 'emu:' and ep.first
		dbg.pc = ep.first
		w.dbg_widget.code.focus_addr dbg.pc
	end
end

if dasm
	w.display(dasm)
	w.dasm_widget.focus_addr(ep.first) if not ep.empty?
	opts[:plugin].to_a.each { |p|
		begin
			dasm.load_plugin(p)
		rescue ::Exception
			puts "Error with plugin #{p}: #{$!.class} #{$!}"
		end
	}
	ep.each { |eep|
		if opts[:fast]
			w.dasm_widget.disassemble_fast_deep(eep)
		else
			w.dasm_widget.disassemble(eep)
		end
	}

	if opts[:session]
		if File.exist?(opts[:session])
			if opts[:newsession]
				File.unlink(opts[:session])
			else
				puts "replaying session #{opts[:session]}"
				w.widget.replay_session(opts[:session])
			end
		end
		w.widget.save_session opts[:session]
	end
end

opts[:hookstr].to_a.each { |f| eval f }

Gui.main

