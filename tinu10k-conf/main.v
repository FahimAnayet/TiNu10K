module main

import os
import term
import config

fn main() {
	for {
		mut cfg := config.Config{
			style: 'lean'
			shell: 'nushell'
			os_icon: ''
			langs: ['python', 'rust', 'node', 'zig', 'go', 'lua']
		}

		term.clear()
		println('╔══════════════════════════════════════╗')
		println('║   tinu10k configure - nushell theme  ║')
		println('╚══════════════════════════════════════╝')
		println('')

		cfg = cfg.questions_ask()
		content := cfg.generate_nu()

		// Ask: save / restart / discard
		term.clear()
		println('╔════════════════════════════════════╗')
		println('║                DONE                ║')
		println('╚════════════════════════════════════╝')
		println('')
		config.show_preview(cfg)
		println('')
		println('What now?')
		println('  s) Save to tinu10k.nu')
		println('  r) Restart from beginning')
		println('  d) Discard and exit')
		ans := os.input('Choice [s/r/d]: ').trim_space().to_lower()
		if ans == 'r' {
			continue
		} else if ans == 'd' {
			println('Discarded.')
			return
		}
		// default: save
		os.write_file('tinu10k.nu', content) or { panic('Write failed: $err') }
		println('✓ Saved to tinu10k.nu')
		println('To use: source tinu10k.nu')
		return
	}
}
