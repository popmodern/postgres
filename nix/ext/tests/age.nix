{ self, pkgs }:
let
  pname = "age";
  inherit (pkgs) lib;
  system = pkgs.pkgsLinux.stdenv.hostPlatform.system;
  testLib = import ./lib.nix { inherit self pkgs; };
  smokeSql = builtins.path {
    path = ../../../migrations/tests/extensions/31-age.sql;
    name = "age-smoke.sql";
  };

  installedExtension =
    postgresMajorVersion: self.legacyPackages.${system}."psql_age-${postgresMajorVersion}".exts."${pname}";
  versions = postgresqlMajorVersion: (installedExtension postgresqlMajorVersion).versions;
in
pkgs.testers.runNixOSTest {
  name = pname;
  nodes.server =
    { ... }:
    {
      imports = [
        (testLib.makeSupabaseTestConfig {
          majorVersion = "15";
          packageName = "psql_age-15";
        })
      ];

      specialisation.postgresql17.configuration = testLib.makeUpgradeSpecialisation {
        fromMajorVersion = "15";
        toMajorVersion = "17";
        fromPackageName = "psql_age-15";
        toPackageName = "psql_age-17";
      };

      # No OrioleDB specialization on purpose: Apache AGE is not supported there.
    };
  testScript =
    { nodes, ... }:
    let
      pg17-configuration = "${nodes.server.system.build.toplevel}/specialisation/postgresql17";
    in
    ''
      from pathlib import Path
      versions = {
        "15": [${lib.concatStringsSep ", " (map (s: ''"${s}"'') (versions "15"))}],
        "17": [${lib.concatStringsSep ", " (map (s: ''"${s}"'') (versions "17"))}],
      }
      extension_name = "${pname}"
      support_upgrade = True
      pg17_configuration = "${pg17-configuration}"
      sql_test_directory = Path("${../../tests}")

      ${builtins.readFile ./lib.py}

      def smoke_age():
          server.succeed(
              "psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -f ${smokeSql}"
          )

      start_all()

      server.wait_for_unit("supabase-db-init.service")

      with subtest("Verify PostgreSQL 15 is our custom build"):
        pg_version = server.succeed(
          "psql -U supabase_admin -d postgres -t -A -c \"SELECT version();\""
        ).strip()
        assert "${testLib.expectedVersions."15"}" in pg_version, (
          f"Expected version ${testLib.expectedVersions."15"}, got: {pg_version}"
        )

      test = PostgresExtensionTest(server, extension_name, versions, sql_test_directory, support_upgrade)

      with subtest("Check upgrade path with postgresql 15"):
        test.check_upgrade_path("15")

      with subtest("Run AGE smoke test on postgresql 15"):
        smoke_age()

      last_version = None
      with subtest("Check the install of the last version of the extension"):
        last_version = test.check_install_last_version("15")

      with subtest("switch to postgresql 17"):
        server.succeed(
          f"{pg17_configuration}/bin/switch-to-configuration test >&2"
        )
        server.wait_for_unit("postgresql.service")

      has_update_script = server.succeed(
        "test -f /var/lib/postgresql/update_extensions.sql && echo yes || echo no"
      ).strip() == "yes"
      if has_update_script:
        test.run_sql_file("/var/lib/postgresql/update_extensions.sql")

      with subtest("Verify PostgreSQL 17 is our custom build"):
        pg_version = server.succeed(
          "psql -U supabase_admin -d postgres -t -A -c \"SELECT version();\""
        ).strip()
        assert "${testLib.expectedVersions."17"}" in pg_version, (
          f"Expected version ${testLib.expectedVersions."17"}, got: {pg_version}"
        )

      with subtest("Check last version of the extension after upgrade"):
        if has_update_script:
          test.assert_version_matches(versions["17"][-1])
        else:
          test.assert_version_matches(last_version)

      with subtest("Check upgrade path with postgresql 17"):
        test.check_upgrade_path("17")

      with subtest("Run AGE smoke test on postgresql 17"):
        smoke_age()
    '';
}