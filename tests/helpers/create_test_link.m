function available = create_test_link(targetPath, linkPath, kind)
%CREATE_TEST_LINK Create a filesystem-link fixture using Java's native API.
% Returns false only when the platform cannot provide this fixture. Other
% failures remain test failures. Neither path is passed through a shell.

arguments
    targetPath (1,:) char
    linkPath (1,:) char
    kind (1,:) char {mustBeMember(kind, {'symbolic', 'hard'})} = 'symbolic'
end

target = java.nio.file.Paths.get(targetPath, javaArray('java.lang.String', 0));
link = java.nio.file.Paths.get(linkPath, javaArray('java.lang.String', 0));
try
    if strcmp(kind, 'symbolic')
        attributes = javaArray('java.nio.file.attribute.FileAttribute', 0);
        java.nio.file.Files.createSymbolicLink(link, target, attributes);
    else
        java.nio.file.Files.createLink(link, target);
    end
catch ME
    unsupported = contains(ME.message, 'UnsupportedOperationException');
    windowsPrivilege = ispc && strcmp(kind, 'symbolic') && ...
        contains(lower(ME.message), 'privilege');
    if ~(unsupported || windowsPrivilege)
        rethrow(ME);
    end
    warning('SIMPLE:Tests:LinkUnavailable', ...
        'Skipping %s-link fixture: %s', kind, ME.message);
    available = false;
    return
end
available = true;
end
