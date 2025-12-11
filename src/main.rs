use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use colored::*;
use directories::BaseDirs;
use reqwest::blocking::Client;
use serde::Deserialize;
use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;

const REPO_ORGANIZATION: &str = "duck-compiler";
const REPO_NAME: &str = "duckc";
const BINARY_NAME: &str = "dargo";

#[derive(Parser)]
#[command(name = "duckup")]
#[command(about = "The duck compiler toolchain manager", long_about = None)]
struct DuckUpCli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    Install {
        version: String,
    },
    Update,
    List,
    Use {
        version: String,
    },
    Run {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },
    Env,
}

#[derive(Debug, Deserialize)]
struct Asset {
    name: String,
    browser_download_url: String,
}

#[derive(Debug, Deserialize)]
struct Release {
    tag_name: String,
    assets: Vec<Asset>,
}

fn main() -> Result<()> {
    let cli = DuckUpCli::parse();

    let (data_dir, bin_dir) = get_duck_directories()?;
    let toolchain_dir = data_dir.join("toolchains");

    fs::create_dir_all(&toolchain_dir)?;
    fs::create_dir_all(&bin_dir)?;

    match cli.command {
        Commands::Install { version } => {
            install_version(&version, &toolchain_dir)?;
        }
        Commands::Update => {
            println!("{} {}", " ".on_green(), "checking for updates...".cyan());
            let latest = fetch_latest_tag()?;
            println!("{} found latest nightly: {}", " ".on_green(), latest.green().bold());
            install_version(&latest, &toolchain_dir)?;
            set_active(&latest, &toolchain_dir, &bin_dir)?;
        }
        Commands::List => {
            list_installed(&toolchain_dir, &bin_dir)?;
        }
        Commands::Use { version } => {
            set_active(&version, &toolchain_dir, &bin_dir)?;
        }
        Commands::Run { args } => {
            run_dargo(&bin_dir, args)?;
        }
        Commands::Env => {
            print_env_info(&toolchain_dir, &bin_dir);
        }
    }

    Ok(())
}

fn get_duck_directories() -> Result<(PathBuf, PathBuf)> {
    let base = BaseDirs::new()
        .context("could not find home directory")?;
    let home = base.home_dir();

    let data_dir = if let Ok(xdg_data) = env::var("XDG_DATA_HOME") {
        PathBuf::from(xdg_data).join("duckup")
    } else if cfg!(target_os = "windows") {
        base.data_local_dir().join("duck-compiler").join("duckup")
    } else {
        home.join(".local").join("share").join("duckup")
    };

    let bin_dir = if let Ok(xdg_bin) = env::var("XDG_BIN_HOME") {
        PathBuf::from(xdg_bin)
    } else if cfg!(target_os = "windows") {
        data_dir.join("bin")
    } else {
        home.join(".local").join("bin")
    };

    Ok((data_dir, bin_dir))
}

fn install_version(tag: &str, toolchain_dir: &Path) -> Result<()> {
    let install_path = toolchain_dir.join(tag);
    if install_path.exists() {
        println!("{} version {} is already installed.", " ".on_yellow(), tag.bold());
        return Ok(());
    }

    println!("{} installing {}...", " duckup ".on_yellow(), tag.cyan());

    let target_filename = get_target_filename()?;
    println!("{} detected platform: {}", " ".on_green(), target_filename);

    let client = Client::builder().user_agent("duckup").build()?;
    let url = format!(
        "https://api.github.com/repos/{}/{}/releases/tags/{}",
        REPO_ORGANIZATION, REPO_NAME, tag
    );

    let resp = client.get(&url).send()?;
    if !resp.status().is_success() {
        bail!("{} release {} not found on github.", " error ".on_bright_red(), tag.red());
    }

    let release: Release = resp.json()?;

    let asset = release.assets.iter()
        .find(|a| a.name == target_filename)
        .context(format!("Could not find binary '{}' in release {}", target_filename, tag))?;

    println!("{} Downloading {}...", "download:".green(), asset.browser_download_url);
    let mut resp = client.get(&asset.browser_download_url).send()?;

    fs::create_dir_all(&install_path)?;
    let binary_dest = install_path.join(BINARY_NAME);
    let mut file = fs::File::create(&binary_dest)?;

    io::copy(&mut resp, &mut file)?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(&binary_dest)?.permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&binary_dest, perms)?;
    }

    println!("{} Installed {} successfully.", " success ".on_green().bold(), tag);
    Ok(())
}

fn set_active(tag: &str, toolchain_dir: &Path, bin_dir: &Path) -> Result<()> {
    let source_path = toolchain_dir.join(tag).join(BINARY_NAME);
    let link_path = bin_dir.join(BINARY_NAME);

    if !source_path.exists() {
        bail!("Version {} is not installed. Run '{}' first.", tag.red(), format!("duckup install {}", tag).yellow());
    }

    if link_path.exists() {
        fs::remove_file(&link_path)?;
    }

    fs::hard_link(&source_path, &link_path)
        .or_else(|_| fs::copy(&source_path, &link_path).map(|_| ()))
        .context("failed to link binary to bin directory")?;

    println!("{} switched to {}.", " success ".on_green().bold(), tag.cyan());
    Ok(())
}

fn list_installed(toolchain_dir: &Path, bin_dir: &Path) -> Result<()> {
    println!("{}", "installed toolchains:".bold().underline());

    let active_bin = bin_dir.join(BINARY_NAME);
    let active_meta = fs::metadata(&active_bin).ok();

    if !toolchain_dir.exists() {
        println!("  (No toolchains found)");
        return Ok(());
    }

    for entry in fs::read_dir(toolchain_dir)? {
        let entry = entry?;
        if entry.metadata()?.is_dir() {
            if let Some(name) = entry.file_name().to_str() {
                let mut is_active = false;

                if let Some(meta) = &active_meta {
                     if let Ok(entry_bin_meta) = fs::metadata(entry.path().join(BINARY_NAME)) {
                         #[cfg(unix)]
                         {
                            use std::os::unix::fs::MetadataExt;
                            if meta.ino() == entry_bin_meta.ino() {
                                is_active = true;
                            }
                         }
                         #[cfg(not(unix))]
                         {
                             if meta.len() == entry_bin_meta.len() {
                                 // Basic fallback for Windows
                             }
                         }
                     }
                }

                if is_active {
                    println!("  {} {}", name.green(), "(active)".cyan());
                } else {
                    println!("  {}", name);
                }
            }
        }
    }
    Ok(())
}

fn run_dargo(bin_dir: &Path, args: Vec<String>) -> Result<()> {
    let binary = bin_dir.join(BINARY_NAME);
    if !binary.exists() {
        bail!("no active toolchain selected. run '{}' first.", "duckup update".yellow());
    }

    let status = Command::new(binary)
        .args(args)
        .status()
        .context("failed to execute dargo")?;

    if !status.success() {
        std::process::exit(status.code().unwrap_or(1));
    }

    Ok(())
}

fn print_env_info(toolchain_dir: &Path, bin_dir: &Path) {
    println!("{}", "Duckup Environment".on_yellow());

    let mut any_not_set = false;
    if let Ok(xdg_data) = env::var("XDG_DATA_HOME") {
        println!("  {}: {}", "XDG_DATA_HOME".cyan(), xdg_data);
    } else {
        println!("  {}: {} (using default, {toolchain_dir:?})", "XDG_DATA_HOME".cyan(), "not set".dimmed());
        any_not_set = true;
    }

    if let Ok(xdg_bin) = env::var("XDG_BIN_HOME") {
        println!("  {}: {}", "XDG_BIN_HOME ".cyan(), xdg_bin);
    } else {
        println!("  {}: {} (using default {:?})", "XDG_BIN_HOME ".cyan(), "not set".dimmed(), bin_dir);
        any_not_set = true;
    }

    if any_not_set {
        println!("{} preferring xdg base directories from env (read more here: {})", " ".on_bright_yellow(), "https://wiki.archlinux.org/title/XDG_Base_Directory".blue());
    }

    println!("---------------------------------------");
    println!("{}: {:?}", "toolchain dir".green(), toolchain_dir);
    println!("{}: {:?}", "binary dir   ".green(), bin_dir);
    println!("");

    let path_env = env::var_os("PATH").unwrap_or_default();
    let path_str = path_env.to_string_lossy();
    let bin_str = bin_dir.to_string_lossy();

    if path_str.contains(&*bin_str) {
        println!("{}", "✅ binary directory is in your PATH".green());
    } else {
        println!("{}", "⚠️  binary directory is NOT in your PATH".yellow());
        println!("   add this to your shell profile:");
        println!("   export PATH=\"$PATH:{}\"", bin_str.cyan());
    }
}

fn fetch_latest_tag() -> Result<String> {
    let client = Client::builder().user_agent("duckup").build()?;

    let url_latest = format!(
        "https://api.github.com/repos/{}/{}/releases/latest",
        REPO_ORGANIZATION,
        REPO_NAME
    );

    if let Ok(resp) = client.get(&url_latest).send() {
        if resp.status().is_success() {
             if let Ok(release) = resp.json::<Release>() {
                 return Ok(release.tag_name);
             }
        }
    }

    let url_list = format!(
        "https://api.github.com/repos/{}/{}/releases?per_page=1",
        REPO_ORGANIZATION, REPO_NAME
    );

    let resp = client.get(&url_list).send()?;
    let releases: Vec<Release> = resp.json()?;

    releases.first()
        .map(|r| r.tag_name.clone())
        .context("No releases found")
}

fn get_target_filename() -> Result<String> {
    let os = std::env::consts::OS;
    let arch = std::env::consts::ARCH;

    let os_str = match os {
        "linux" | "macos" | "windows" => os,
        _ => bail!("unsupported os: {}", os),
    };

    let arch_str = match arch {
        "x86_64" => "x86_64",
        "aarch64" => "aarch64",
        "arm" => "armv7",
        _ => bail!("unsupported architecture: {}", arch),
    };

    let ext = if os == "windows" { ".exe" } else { "" };
    Ok(format!("dargo-{}-{}{}", os_str, arch_str, ext))
}
