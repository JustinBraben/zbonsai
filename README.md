[![Zig](https://img.shields.io/badge/-Zig-F7A41D?style=flat&logo=zig&logoColor=white)](https://ziglang.org/) ⚡

# zbonsai

![zbonsai_capture.png](https://github.com/JustinBraben/zbonsai/blob/main/zbonsai_capture.PNG)

Inspired by [cbonsai](https://gitlab.com/jallbrit/cbonsai), zbonsai is a Zig-based terminal application that procedurally generates beautiful bonsai trees in your command line interface. zbonsai brings the zen of bonsai to your terminal, reimagined in the Zig programming language.

## Features

- Procedurally generated bonsai trees
- Customizable tree parameters
- Terminal-based user interface using libvaxis
- Command-line argument parsing with zig-clap

## Installation

To install zbonsai, you'll need to have Zig `0.13.0` on your system. Then, follow these steps:

1. Clone the repository:
   ```
   git clone https://github.com/JustinBraben/zbonsai.git
   cd zbonsai
   ```

2. Build the project:
   ```
   zig build
   ```

3. Run zbonsai:
   ```
   zig build run
   ```

## Usage

Basic usage:

```
zig build run
```

For more options, use the `--help` flag:

```
zig build run -- --help
```

To generate and view the tree live:

```
zig build run -- -l
```

Generate tree live with verbose output.

```
zig build run -- -l -v minimal
```

## Dependencies

- [libvaxis](https://github.com/libvaxis/libvaxis): A Zig library for creating terminal user interfaces
- [zig-clap](https://github.com/Hejsil/zig-clap): A command-line argument parser for Zig

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgements

- Inspired by [cbonsai](https://gitlab.com/jallbrit/cbonsai)
- Built with [Zig](https://ziglang.org/)

## TODO

- [x] Generating Bonsai
- [x] Three different plant bases
- [x] Instantly view generated tree
- [x] Live view of tree generating by optionally passing `-l`
- [ ] Implement message box
- [ ] Implement print to terminal on completion `-p`
- [ ] Implement file saving and loading
- [ ] Add option to use different Random Number Generators
- [ ] Add benchmarking/testing
- [ ] Improve resizing 
- [ ] Improve documentation

---

*Note: This project is a work in progress and is primarily for learning purposes.*