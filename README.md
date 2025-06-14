<p align="center">
  <img src="https://github.com/funcieqDEV/Atra/blob/main/arts/main.png?raw=true" width="400px"><br>
  <img src="https://img.shields.io/github/v/release/olix3001/atra-zig">
  <img src="https://img.shields.io/github/commit-activity/m/olix3001/atra-zig">
  <img src="https://img.shields.io/github/stars/olix3001/atra-zig?style=social">
  <img src="https://img.shields.io/github/license/olix3001/atra-zig">
</p>

This is a reimagined version of [funcieqDEV's](https://github.com/funcieqDEV) [Atra](https://github.com/funcieqDEV/Atra) html template engine.
I **DO NOT** plan on supporting this project in the future,
as it is only made for the purpose of learning zig programming language.
However at this point this project is kinda complete, with support for all major features (unstable).

## ✨ Features

- **Component-based architecture** - Reusable components with `@<macro>` declarations,
- **Modern syntax** - Clean and readable syntax,
- **Blazing fast compilation** - Built with Zig for maximum performance,
- **Hot reloading** - Watch mode for instant development feedback (unavailable),
- **Static output** - Generates (kinda) optimized HTML files.

## 🏎️ Performance

This project is written with performance in mind.
To squeeze out the most from even worst PCs, heap allocations are used only
where unavoidable. For example lexer (sometimes called scanner) does not allocate anything,
but instead It works like an iterator scanning every token on demand, returning pointer to the original
source instead of copying the data.

There are many more tricks like this, all of which combined give unbelievable performance!
Compiling file with 10000 lines takes less than 40ms on my computer, 30 of which are system calls.

## 🚀 Quick Start

### Installation

#### From Releases (Recommended)

1. Download the latest release from [GitHub Releases](https://github.com/olix3001/atra-zig/releases)

**Windows & MacOS**
Just run the installer from github releases. (or compile if unavailable)

**Linux**
If you are using linux then just compile from source lol.
It's just one command.

#### Building from Source

```bash
git clone https://github.com/olix3001/atra-zig.git
cd atra-zig
# TODO: There is no build/install step in build.zig at this moment.
# You can try Atra with `zig build run -- <arguments>`.
```

## 📖 Usage

### Basic Commands

```bash
# Build single file (will output file.html)
atra build file.atra

# Build all directory.
# This will compile all files whose names start with '+' symbol.
# For example, if you name your file +index.atra, it will compile It as index.html.
# This keeps project structure relative to project root, output is located in atra-out folder.
atra build ./my-project

# Watch for changes and rebuild automatically.
# This exposes development server on localhost:3000.
# If using directory index.atra will be used as /.
atra watch file.atra

# Same as above.
atra watch ./my-project
```

### Basic Example

Create `index.atra` file:

```atra
@section(title, description, *children) {
    div {
        h1 { $title }
        h3(style="margin-top: -1.5rem; font-size: 0.85rem; color: grey;") { $description }
        $children
    }
}

html(lang="en") {
    head {
        title { "Atra!" }
        meta(charset="utf")
    }
    body {
        %section(title="Intrinsics", description="Atra supports builtin functions like repetitions!") {
            %repeat(n=3) |i| {
                p {
                    "I am a repeated tag number " $i "!"
                    %repeat(n=$i) |j| {
                        span { " | I am subrepeat number " $j }
                    }
                }
            }
        }

        %section(title="Source", description="This is a source code of this file... kinda trippy :D") {
            code { pre { %embedText(src="./index.atra") } }
        }
    }
}
```

This generates optimized html. There will be no indentations, because who really needs them (and they can break indentation in things like code or pre tags)?

### Macros

Create reusable components with `@<macro>` declarations.
In the previous example there is `@section` at the top of the file.
This declaration is a macro, you can use It as many times as you want in your project.
Macro declarations are available only in the current scope, and under the declaration itself.

#### Loops

```atra
ul {
    %repeat(n=13) |i| {
        li { "element " $i }
    }
}
```

Here we use `%repeat` builtin, that exposes one capture (here we name it `i`), being the index of current iteration.

## Includes

You can include other atra files in your project using `%include` builtin.
This will cache included module for maximum performance!

\*Included file will be cached separately for every root, meaning every file in the main directory.
This behavor may change in the future by implementing global cache.

```atra
%include(src="./other.atra")
```

## 🤝 Contributing

We welcome contributions! Here's how you can help:

1. **Fork the repository**
2. **Create a feature branch**: `git checkout -b feature/amazing-feature`
3. **Commit your changes**: `git commit -m 'Add amazing feature'`
4. **Push to the branch**: `git push origin feature/amazing-feature`
5. **Open a Pull Request**

### Development Setup

I recommend using `zed` with `Zig` extension configured like the following (zed's settings.json):

```json
"languages": {
  "Zig": {
    "format_on_save": "language_server",
    "language_servers": ["zls"],
    "code_actions_on_format": {
      "source.organizeImports": true
    }
  }
},
"lsp": {
  "zls": {
    "binary": {
      // "path": "/opt/homebrew/bin/zls"
      "path": "/Users/oliwiermichalik/Documents/zls/zig-out/bin/zls"
    },
    "settings": {
      "enable_build_on_save": true
    }
  }
}
```

However, you can use whatever you like, even plain windows notepad... I do not care.

### Code Style

I'm waaay too lazy to write code style guide, so just try to keep it clean and silimar to the
rest of the codebase.

## 📝 Examples

Examples may or may not be added in the future.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🌟 Support

If you find Atra useful, please consider:

- ⭐ Starring the repository
- 🐛 Reporting bugs
- 💡 Suggesting new features
- 📖 Improving documentation

## 📞 Contact

- GitHub Issues: [Report bugs or request features](https://github.com/olix3001/atra-zig/issues)
  (I probably will not fix them.)
- Discussions: [Community discussions](https://github.com/olix3001/atra-zig/discussions)
- discord: nope.

---

Built with ❤️ in Zig
