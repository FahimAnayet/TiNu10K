module config

import os

pub fn (mut c Config) questions_ask() Config {
	// Auto-detect OS icon if not set
	if c.os_icon == '' {
		c.os_icon = detect_os_icon()
	}

	// Show initial preview
	show_preview(c)

	// Shell selection
	println('[0/8] Choose shell:')
	c.shell = ask_choice('Shell [0-2/q]:', ['nushell', 'zsh', 'fish'])
	show_preview(c)

	// Style
	println('[1/8] Choose prompt style:')
	c.style = ask_choice('Style [0-3/q]:', ['lean', 'pure', 'rainbow', 'classic'])

	// Transient
	println('[2/8] Enable transient prompt? (shorter after cmd)')
	c.transient = ask_bool('Transient ', false)
	show_preview(c)

	// Sparse
	println('[3/8] Enable sparse prompt? (shorter after cmd)')
	c.sparse = ask_bool('Sparse ', false)
	show_preview(c)

	// Two-line
	println('[4/8] Two-line prompt? (path top, rest bottom)')
	c.two_line = ask_bool('Two-line ', false)
	if c.two_line {
		println('[3b] Frame style:')
		c.frame = ask_choice('Frame [0-2/q]:', ['none', 'sharp', 'rounded', 'soft'])
	}
	show_preview(c)

	// Icons
	println('[5/8] Show icons? (OS, git, langs)')
	c.icons = ask_bool('Icons ', true)
	show_preview(c)

	// Languages
	println('[6/8] Select languages to show(press enter/y for yes):')
	avail := ['python', 'rust', 'zig', 'node', 'go', 'lua', 'v']
	mut selected := []string{}
	for l in avail {
		if ask_bool('  ${l} :', c.langs.contains(l)) {
			selected << l
		}
	}
	c.langs = selected
	show_preview(c)

	// OS icon
	println('[7/8] Custom OS icon (empty=keep auto, q=quit):')
	icon := os.input('Icon: ')
	if icon.trim_space() == 'q' {
		exit(0)
	}
	if icon.trim_space() != '' {
		c.os_icon = icon
	}
	show_preview(c)

	return c
}

fn detect_os_icon() string {
	mut icon := '󰟀 '

	// Get the base OS kernel name
	kernel := os.user_os()

	match kernel {
		'windows' { return ' ' }
		'darwin'  { return ' ' }
		'linux'   {
			// Read os-release to find the specific distro
			release_info := os.read_file('/etc/os-release') or { '' }

			if release_info.contains('ID=cachyos') {
				return '󰚌 '
			} else if release_info.contains('ID=arch') {
				return ' '
			} else if release_info.contains('ID=nixos') {
				return ' '
			} else if release_info.contains('ID=fedora') {
				return ' '
			}

			return ' ' // Default Linux icon
		}
		else { return icon }
	}
}

fn ask_choice(prompt string, options []string) string {
	for i, opt in options {
		println('  ${i}) ${opt}')
	}
	mut ans := os.input('${prompt} ').trim_space()
	for {
		if ans == 'q' {
			exit(0)
		}
		if ans.is_int() {
			idx := ans.int()
			if idx >= 0 && idx < options.len {
				return options[idx]
			}
		}
		ans = os.input('Invalid. Choose 0-${options.len - 1} or q: ').trim_space()
	}
	return '' // unreachable
}

fn ask_bool(prompt string, default bool) bool {
	d := if default { 'Y/n/q' } else { 'y/N/q' }
	ans := os.input('${prompt} [${d}]: ').trim_space().to_lower()
	if ans == 'q' {
		exit(0)
	}
	if ans == '' {
		return default
	}
	return ans == 'y' || ans == 'yes'
}
