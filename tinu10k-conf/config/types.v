module config

pub struct Config {
pub mut:
	style       string
	shell       string // nushell, zsh, fish (future)
	transient   bool
	sparse   	bool
	two_line    bool
	frame       string // none, sharp, rounded, soft
	icons       bool
	langs       []string
	os_icon     string
}
