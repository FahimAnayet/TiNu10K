module config

import term

pub fn show_preview(c Config) {
	term.clear()
	println('════════════════════════════════════════════════════════════════════════════════════')
	println('  					 PREVIEW 										  ')
	println('════════════════════════════════════════════════════════════════════════════════════')
	println('')

	left := build_left(c)
	right := build_right(c)

	// Get terminal width
	w, _ := term.get_terminal_size()
	right_w := str_width(right)
	pad := if w - right_w > 0 { w - right_w } else { 0 }

	// Print left and right on same line
	print(left)
	if pad > str_width(left) {
		for _ in 0..(pad - str_width(left) - 1) {
			print(' ')
		}
	}
	println(right)

	println('')
	println('Config: style=$c.style sparse=$c.sparse two_line=$c.two_line icons=$c.icons')
	println('Config: style=$c.style transient=$c.transient two_line=$c.two_line icons=$c.icons')
	println('Langs: $c.langs')
	if c.two_line { println('Frame: $c.frame (sharp=┌─, rounded/soft=╭─)') }
	println('---')
}

fn str_width(s string) int {
	mut count := 0
	mut in_esc := false
	for ch in s {
		if ch == `\x1b` { in_esc = true }
		if in_esc {
			if ch == `m` { in_esc = false }
			continue
		}
		count++
	}
	return count
}

fn build_left(c Config) string {
	mut left := ''
	if c.style == 'rainbow' || c.style == 'classic' {
		bg := if c.style == 'classic' { '\x1b[48;5;238m' } else { '\x1b[48;5;110m' }
		fg := '\x1b[38;5;231m'
		reset := '\x1b[0m'
		os_icon := if c.icons { c.os_icon } else { '' }
		left = '${bg}${fg} ${os_icon} ~ ${reset}${bg}/neovim/.../autoload'
		if c.icons {
			left += ' ${reset}\x1b[48;5;114m\x1b[38;5;16m master ↑2${reset}'
		} else {
			left += ' ${reset} master ↑2 '
		}
	} else {
		if c.style == 'pure' {
			left = '\x1b[38;5;248m'
		} else {
			left = '\x1b[38;5;75m'
		}
		if c.icons { left += c.os_icon }
		left += ' ~'
		left += '\x1b[0m/neovim/'
		if c.style == 'pure' {
			left += '\x1b[38;5;248m.../autoload  master ↑2\x1b[0m'
		} else {
			left += '\x1b[38;5;75m.../autoload \x1b[38;5;148m master ↑2\x1b[0m'
		}
	}
	if c.transient { left = '>' + '\n' + left }
	if c.sparse { left = '>' + '\n' + '\n' + left }
	if c.two_line { left = left + '\n' + '>'}
	return left
}

fn build_right(c Config) string {
	mut right := '\x1b[38;5;196m✘ 1 \x1b[38;5;148m 1.2s\x1b[0m'
	if c.icons {
		for l in c.langs {
			match l {
				'python' { right += ' \x1b[38;5;226m 3.12\x1b[0m' }
				'rust'   { right += ' \x1b[38;5;196m 1.85\x1b[0m' }
				'zig'    { right += ' \x1b[38;5;226m 0.14\x1b[0m' }
				'node'   { right += ' \x1b[38;5;112m 20.0\x1b[0m' }
				'go'     { right += ' \x1b[38;5;87m 1.22\x1b[0m' }
				'lua'    { right += ' \x1b[38;5;75m 5.4\x1b[0m' }
				'v'      { right += ' \x1b[38;5;75m 0.4\x1b[0m' }
				else     { }
			}
		}
	} else {
		for l in c.langs {
			right += ' $l 3.12'
		}
	}
	return right
}
