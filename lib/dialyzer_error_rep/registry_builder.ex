defmodule DialyzerErrorRep.RegistryBuilder do
  require Logger

  def build() do
    public_dir = Application.fetch_env!(:dialyzer_error_rep, :public_dir)
    registry_name = Application.fetch_env!(:dialyzer_error_rep, :registry_name)

    private_key =
      Application.fetch_env!(:dialyzer_error_rep, :private_key)
      |> Base.decode64!()
      |> decode_private_key()

    build(registry_name, public_dir, private_key)
  end

  def build(repo_name, public_dir, private_key) do
    ensure_public_key(private_key, public_dir)
    create_directory(Path.join(public_dir, "tarballs"))

    paths_per_name =
      Enum.group_by(Path.wildcard("#{public_dir}/tarballs/*.tar"), fn path ->
        [name | _rest] = String.split(Path.basename(path), ["-", ".tar"], trim: true)
        name
      end)

    versions =
      Enum.map(paths_per_name, fn {name, paths} ->
        releases =
          paths
          |> Enum.map(&build_release(repo_name, &1))
          |> Enum.sort(&(Version.compare(&1.version, &2.version) == :lt))

        updated_at =
          paths
          |> Enum.map(&File.stat!(&1).mtime)
          |> Enum.sort()
          |> Enum.at(-1)

        updated_at = updated_at && %{seconds: to_unix(updated_at), nanos: 0}

        package =
          :mix_hex_registry.build_package(
            %{repository: repo_name, name: name, releases: releases},
            private_key
          )

        write_file("#{public_dir}/packages/#{name}", package)
        versions = Enum.map(releases, & &1.version)
        {name, %{updated_at: updated_at, versions: versions}}
      end)

    for path <- Path.wildcard("#{public_dir}/packages/*"),
        not Enum.member?(Map.keys(paths_per_name), Path.basename(path)) do
      remove_file(path)
    end

    names =
      for {name, %{updated_at: updated_at}} <- versions do
        %{name: name, updated_at: updated_at}
      end

    payload = %{repository: repo_name, packages: names}
    names = :mix_hex_registry.build_names(payload, private_key)
    write_file("#{public_dir}/names", names)

    versions =
      for {name, %{versions: versions}} <- versions do
        %{name: name, versions: versions}
      end

    payload = %{repository: repo_name, packages: versions}
    versions = :mix_hex_registry.build_versions(payload, private_key)
    write_file("#{public_dir}/versions", versions)
  end

  @unix_epoch :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})

  @doc false
  def to_unix(erl_datetime) do
    :calendar.datetime_to_gregorian_seconds(erl_datetime) - @unix_epoch
  end

  def get_packages(repo_name, public_dir) do
    Path.wildcard("#{public_dir}/tarballs/*.tar")
    |> Enum.group_by(fn path ->
      [name | _rest] = String.split(Path.basename(path), ["-", ".tar"], trim: true)
      name
    end)
    |> Enum.map(fn {name, paths} ->
      releases =
        paths
        |> Enum.map(&build_release(repo_name, &1))
        |> Enum.sort(&(Version.compare(&1.version, &2.version) == :lt))

      %{name: name, versions: Enum.map(releases, & &1.version)}
    end)
  end

  defp build_release(repo_name, tarball_path) do
    tarball = File.read!(tarball_path)
    {:ok, result} = :mix_hex_tarball.unpack(tarball, :memory)

    dependencies =
      for {package, map} <- Map.get(result.metadata, "requirements", []) do
        app = Map.fetch!(map, "app")
        requirement = Map.fetch!(map, "requirement")
        optional = map["optional"] == true
        repository = map["repository"]

        release = %{
          package: package,
          app: app,
          optional: optional,
          requirement: requirement
        }

        if !repository or repository == repo_name do
          release
        else
          Map.put(release, :repository, repository)
        end
      end

    %{
      version: result.metadata["version"],
      inner_checksum: result.inner_checksum,
      outer_checksum: result.outer_checksum,
      dependencies: dependencies
    }
  end

  defp ensure_public_key(private_key, public_dir) do
    path = "#{public_dir}/public_key"
    encoded_public_key = private_key |> extract_public_key() |> encode_public_key()

    case File.read(path) do
      {:ok, ^encoded_public_key} ->
        :ok

      {:ok, _} ->
        Hex.Shell.info("* public key at #{path} does not match private key, overwriting")
        write_file(path, encoded_public_key)

      {:error, :enoent} ->
        write_file(path, encoded_public_key)
    end
  end

  defp create_directory(path) do
    unless File.dir?(path) do
      Hex.Shell.info(["* creating ", path])
      File.mkdir_p!(path)
    end
  end

  defp write_file(path, data) do
    if File.exists?(path) do
      Hex.Shell.info(["* updating ", path])
    else
      File.mkdir_p!(Path.dirname(path))
      Hex.Shell.info(["* creating ", path])
    end

    File.write!(path, data)
  end

  defp remove_file(path) do
    Hex.Shell.info(["* removing ", path])
    File.rm!(path)
  end

  ## Key utilities

  require Record

  Record.defrecordp(
    :rsa_private_key,
    :RSAPrivateKey,
    Record.extract(:RSAPrivateKey, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :rsa_public_key,
    :RSAPublicKey,
    Record.extract(:RSAPublicKey, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  defp extract_public_key(rsa_private_key(modulus: m, publicExponent: e)) do
    rsa_public_key(modulus: m, publicExponent: e)
  end

  defp encode_public_key(key) do
    :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPublicKey, key)])
  end

  defp decode_private_key(data) do
    [entry] = :public_key.pem_decode(data)
    :public_key.pem_entry_decode(entry)
  end
end
