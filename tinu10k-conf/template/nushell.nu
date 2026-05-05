def get-prompt-data []: nothing -> string {
  let langs = ($env.PROMPT_LANGS? | default [] | str join ,)

  let data = (try {
    tinu10k prompt $env.PWD (term size).columns $langs | from json
  } | default {prefix:"", segments: [], git: null, languages: {}})

  $env.LAST_PROMPT_DATA = $data
  return $data
}

def left-prompt []: nothing -> string {
  let data = ($env.LAST_PROMPT_DATA? | default {prefix:"", segments: [], git: null})

  let style = $env.TINU10K_STYLE

  if $style == 'rainbow' or $style == 'classic' {
    # Rainbow / Classic style (powerline)
    let c_os    = {bg: "#eeeeee" fg: "#000000"}
    let c_prefix = if $style == 'classic' { {bg: "#666666" fg: "#ffffff"} } else { {bg: "#7e9cd8" fg: "#ffffff"} }
    let c_path   = if $style == 'classic' { {bg: "#666666" fg: "#ffffff"} } else { {bg: "#7e9cd8" fg: "#ffffff"} }
    let c_git    = if $style == 'classic' { {bg: "#666666" fg: "#98bb6c"} } else { {bg: "#98bb6c" fg: "#000000"} }
    let c_dirty  = if $style == 'classic' { {bg: "#666666" fg: "#ffa066"} } else { {bg: "#ffa066" fg: "#000000"} }

    let sep = ""
    let reset = (ansi reset)

    mut prompt = $"(ansi -e $c_os) ($env.OS_ICON) (ansi -e {fg: $c_os.bg bg: $c_prefix.bg})($sep)"

    $prompt += $"(ansi -e $c_prefix) ($data.prefix)/"

    let last_seg_idx = (($data.segments | length) - 1)
    for i in 0..$last_seg_idx {
        let seg = ($data.segments | get -o $i)
        let style_seg = if $seg.is_anchor { (ansi white_bold) } else { (ansi -e {fg: "#dcd7ba"}) }
        let slash = if $i == $last_seg_idx { "" } else { "/" }
        $prompt += $"($style_seg)($seg.text)($slash)"
    }

    if ($data.git != null and $data.git != 1) {
        let g = $data.git
        let is_dirty = ($g.1 + $g.2 + $g.3 + $g.4) > 0
        let git_colors = if $is_dirty { $c_dirty } else { $c_git }

        $prompt += $"(ansi -e {fg: $c_path.bg bg: $git_colors.bg})($sep)(ansi -e $git_colors) "

        let remote = if ($g.5 == 0) { " " } else { " " }
        let branch = if ($g.0 | is-empty) { $"($g.10)" } else { $" ($g.0)" }
        $prompt += $"($remote)($branch) "

        mut status = ""
        if $g.2 > 0 { $status += $" (ansi yellow)!($g.2)" }
        if $g.3 > 0 { $status += $" (ansi cyan)?($g.3)" }
        if $g.4 > 0 { $status += $" (ansi red)-($g.4)" }
        if $g.1 > 0 { $status += $" (ansi white)+($g.1)" }
        if $g.6 > 0 { $status += $" (ansi green)⇡($g.6)" }
        if $g.7 > 0 { $status += $" (ansi purple)⇣($g.7)" }
        if $g.8 > 0 { $status += $" (ansi grey)*($g.8)" }
        $prompt += if ($status | is-empty) { "" } else { $"($status) " }

        $prompt += $"($reset)(ansi -e {fg: $git_colors.bg})($sep)"
    } else {
        $prompt += $"($reset)(ansi -e {fg: $c_path.bg})($sep)"
    }

    return $"($prompt)($reset)"
  } else {
    # Lean / Pure style (flat)
    let color_main = if $style == 'pure' { (ansi grey) } else { (ansi blue) }
    mut path_str = $"(ansi cyan)($env.OS_ICON)(ansi reset)($color_main)($data.prefix)(ansi reset)"
    for seg in $data.segments {
      let color = if $seg.is_anchor { (ansi blue_bold) } else if not $seg.is_collapsed { (ansi blue) } else { (ansi grey) }
      $path_str += $"/($color)($seg.text)(ansi reset)"
    }

    mut git_str = ""
    if ($data.git != null and $data.git != 1) {
      let g = $data.git
      let branch_color = if ($g.9 == 1) { (ansi blue_bold) } else { (ansi green_bold) }
      let remote = if ($g.5 == 0) { " " } else { " " }
      let branch = if ($g.0 | is-empty) { $"($g.10)" } else { $" ($g.0)" }
      mut status = ""
      if $g.2 > 0 { $status += $" (ansi yellow)!($g.2)" }
      if $g.3 > 0 { $status += $" (ansi cyan)?($g.3)" }
      if $g.4 > 0 { $status += $" (ansi red)-($g.4)" }
      if $g.1 > 0 { $status += $" (ansi white)+($g.1)" }
      if $g.6 > 0 { $status += $" (ansi green)⇡($g.6)" }
      if $g.7 > 0 { $status += $" (ansi purple)⇣($g.7)" }
      if $g.8 > 0 { $status += $" (ansi grey)*($g.8)" }
      $git_str = $" ($branch_color)($remote)($branch)(ansi reset)($status)"
    }

    $"($path_str)($git_str)"
  }
}

def right-prompt []: nothing -> string {
  let data = ($env.LAST_PROMPT_DATA? | default {languages: {}})
  let last_exit = if $env.LAST_EXIT_CODE != 0 { $"(ansi red_bold)✘ ($env.LAST_EXIT_CODE) " } else { "" }
  let duration = $"($env.CMD_DURATION_MS | into int | $in * 1000000 | into duration)"

  let raw_name = ($env.VIRTUAL_ENV_PROMPT? | default ($env.CONDA_PROMPT_MODIFIER? | default ($env.PIXI_PROMPT? | default "")))
  let env_mod = if ($raw_name | is-not-empty) {
      let clean = ($raw_name | str replace --all --regex '[\(\)\[\]]' '' | str trim)
      $"(ansi cyan)[($clean)](ansi reset)"
  } else { "" }

  mut langs = []
  if ($data.languages != null) {
    for l in ($data.languages | columns) {
      let val = ($data.languages | get --optional $l | str trim)
      let icon = match $l {
        "python" => $"(ansi yellow) "
        "rust"   => $"(ansi red) "
        "zig"    => $"(ansi yellow) "
        "node"   => $"(ansi green) "
        "go"     => $"(ansi cyan) "
        "lua"    => $"(ansi blue) "
        "v"      => $"(ansi blue) "
        _        => ""
      }
      if $icon != "" {
        let display = if $val != "" { $" ($icon)($val)" } else { $icon }
        $langs ++= [$"($display)(ansi reset)"]
      }
    }
  }

  $"($last_exit)(ansi green) ($duration)(ansi reset)($langs | str join '')($env_mod)"
}

export-env {
  if not ("/tmp/tinu10k" | path exists) {
    try { mkdir "/tmp/tinu10k" }
  }

  do --ignore-errors { tinu10k daemon start }

  load-env {
    OS_ICON: "󰚌 "
    PROMPT_LANGS: [python rust node zig go lua]
    PROMPT_COMMAND: {|| left-prompt }
    PROMPT_COMMAND_RIGHT: {|| right-prompt }
    PROMPT_INDICATOR: " "
    PROMPT_INDICATOR_VI_INSERT: " "
    PROMPT_INDICATOR_VI_NORMAL: " "
    PROMPT_MULTILINE_INDICATOR: "::: "
    TRANSIENT_PROMPT_COMMAND: ""
    TINU10K_STYLE: lean
  }

  $env.config = ($env.config? | default {} | upsert hooks {
    pre_prompt: [
      {|| $env.LAST_PROMPT_DATA = (get-prompt-data) }
    ]
  }| upsert render_right_prompt_on_last_line true)
}
