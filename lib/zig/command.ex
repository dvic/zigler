defmodule Zig.Command do
  @moduledoc """
  contains all parts of the Zig library involved in calling the
  zig compiler toolchain, especially with regards to the `zig` command, except
  for assembling the build.zig file, which is performed by the
  `Zig.Builder` module.
  """

  alias Zig.Assembler
  alias Zig.Target

  require Logger

  #############################################################################
  ## API

  defp run_zig(command, opts) do
    args = String.split(command)

    base_opts = Keyword.take(opts, [:cd])
    error_opts = Keyword.take(opts, [:cd, :stderr_to_stdout])
    zig_cmd = executable_path(opts)

    case System.cmd(zig_cmd, args, base_opts) do
      {result, 0} ->
        result

      # TODO: better error parsing here
      _ ->
        # rerun it.  This is awful, but we need it to separate out
        # stderr from stdout.
        {error, code} = System.cmd(zig_cmd, args, error_opts) |> dbg(limit: 25)
        raise Zig.CompileError, command: command, code: code, error: error
    end
  end

  def run_sema(file, opts) do
    priv_dir = :code.priv_dir(:zigler)
    sema_file = Path.join(priv_dir, "beam/sema.zig")
    beam_file = Path.join(priv_dir, "beam/beam.zig")
    erl_nif_file = Path.join(priv_dir, "beam/erl_nif.zig")
    sema_on_file = Path.join(priv_dir, "beam/sema/on.zig")

    pkg_opts =
      packages(
        analyte:
          {file,
           beam: {beam_file, sema: sema_on_file, erl_nif: erl_nif_file}, erl_nif: erl_nif_file},
        sema: sema_on_file
      )

    sema_command = "run #{sema_file} #{pkg_opts} #{link_opts(opts)}"

    # Need to make this an OK tuple
    {:ok, run_zig(sema_command, stderr_to_stdout: true)}
  end

  defp packages(packages) do
    Enum.map_join(packages, " ", fn
      {name, {file, deps}} ->
        "--pkg-begin #{name} #{file} #{packages(deps)} --pkg-end"

      {name, file} ->
        "--pkg-begin #{name} #{file} --pkg-end"
    end)
  end

  defp link_opts(opts) do
    # TODO: do we need a more sophisticated way of running this analysis?
    if Keyword.get(opts, :easy_c), do: "-lc"
  end

  def fmt(file) do
    run_zig("fmt #{file}", [])
  end

  def compile(module, opts) do
    assembly_dir = Assembler.directory(module)

    so_dir =
      case Keyword.get(opts, :ebin_dir) do
        :priv ->
          opts
          |> Keyword.fetch!(:otp_app)
          |> :code.lib_dir()
          |> Path.join("priv")

        _ ->
          opts
          |> Keyword.fetch!(:otp_app)
          |> :code.lib_dir()
          |> Path.join("ebin")
      end

    compile_opts =
      Keyword.merge(
        opts,
        stderr_to_stdout: true,
        cd: assembly_dir
      )

    run_zig("build --prefix #{so_dir}", compile_opts)

    lib_name = Path.join(so_dir, "lib/lib#{module}.so")
    naked_name = Path.join(so_dir, "lib/#{module}.so")

    File.rename!(lib_name, naked_name)

    Logger.debug("built library at #{naked_name}")
  end

  defp executable_path(opts) do
    cond do
      opts[:local_zig] -> System.find_executable("zig")
      path = opts[:zig_path] -> path
      true -> Path.join(directory(), "zig")
    end
  end

  # defp maybe_rename_library_filename(fullpath) do
  #  if Path.extname(fullpath) == ".dylib" do
  #    fullpath
  #    |> Path.dirname()
  #    |> Path.join(Path.basename(fullpath, ".dylib") <> ".so")
  #  else
  #    fullpath
  #  end
  # end

  #############################################################################
  ## download zig from online sources.

  @doc false
  def version_name(version) do
    "zig-#{get_os()}-#{get_arch()}-#{version}"
  end

  def get_os do
    case :os.type() do
      {:unix, :linux} ->
        "linux"

      {:unix, :freebsd} ->
        "freebsd"

      {:unix, :darwin} ->
        "macos"

      {_, :nt} ->
        windows_warn()
        "windows"
    end
  end

  @arches %{
    "i386" => "i386",
    "i486" => "i386",
    "i586" => "i386",
    "x86_64" => "x86_64",
    "armv6" => "armv6kz",
    "armv7" => "armv7a",
    "aarch64" => "aarch64",
    "amd64" => "x86_64",
    "win32" => "i386",
    "win64" => "x86_64"
  }

  # note this is the architecture of the machine where compilation is
  # being done, not the target architecture of cross-compiled
  def get_arch do
    arch =
      :system_architecture
      |> :erlang.system_info()
      |> List.to_string()

    Enum.find_value(@arches, fn
      {prefix, zig_arch} -> if String.starts_with?(arch, prefix), do: zig_arch
    end) || raise arch_warn()
  end

  defp arch_warn,
    do: """
      it seems like you are compiling from an unsupported architecture:
        #{:erlang.system_info(:system_architecture)}
      Please leave an issue at https://github.com/ityonemo/zigler/issues
    """

  defp windows_warn do
    Logger.warn("""
    windows is not supported, but may work.

    If you find an error in the process, please leave an issue at:
    https://github.com/ityonemo/zigler/issues
    """)
  end

  @zig_dir_path Path.expand("../../zig", Path.dirname(__ENV__.file))

  defp directory do
    target_string = "zig-#{Target.string(:aaa)}-0.10.1"
    Path.join(@zig_dir_path, target_string)
  end

  # TODO: rename this.
  def fetch(version) do
    zig_dir = Path.join(@zig_dir_path, version_name(version))
    zig_executable = Path.join(zig_dir, "zig")
    :global.set_lock({__MODULE__, self()})

    unless File.exists?(zig_executable) do
      # make sure the zig directory path exists and is ready.
      File.mkdir_p!(@zig_dir_path)

      # make sure that we're in the correct operating system.
      extension =
        if match?({_, :nt}, :os.type()) do
          ".zip"
        else
          ".tar.xz"
        end

      archive = version_name(version) <> extension

      # TODO: clean this up.
      Logger.configure(level: :info)

      zig_download_path = Path.join(@zig_dir_path, archive)
      download_zig_archive(zig_download_path, version, archive)

      # untar the zig directory.
      unarchive_zig(archive)
    end

    :global.del_lock({__MODULE__, self()})
  end

  # https://ziglang.org/download/#release-0.10.1
  # @checksums %{}

  defp download_zig_archive(zig_download_path, version, archive) do
    url = "https://ziglang.org/download/#{version}/#{archive}"
    Logger.info("downloading zig version #{version} (#{url}) and caching in #{@zig_dir_path}.")

    case httpc_get(url) do
      {:ok, %{status: 200, body: body}} ->
        # expected_checksum = Map.fetch!(@checksums, archive)
        # actual_checksum = :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)

        # if expected_checksum != actual_checksum do
        #  raise "checksum mismatch: expected #{expected_checksum}, got #{actual_checksum}"
        # end

        File.write!(zig_download_path, body)

      _ ->
        raise "failed to download the appropriate zig archive."
    end
  end

  defp httpc_get(url) do
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(:inets)
    headers = []
    request = {String.to_charlist(url), headers}
    http_options = [timeout: 600_000]
    options = [body_format: :binary]

    case :httpc.request(:get, request, http_options, options) do
      {:ok, {{_, status, _}, headers, body}} ->
        {:ok, %{status: status, headers: headers, body: body}}

      other ->
        other
    end
  end

  def unarchive_zig(archive) do
    System.cmd("tar", ["xvf", archive], cd: @zig_dir_path)
  end
end
