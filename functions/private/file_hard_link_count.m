function count = file_hard_link_count(pathValue)
%FILE_HARD_LINK_COUNT Count file aliases without changing the file.
% Java exposes the count directly on Unix. Windows provides the same
% information through its built-in fsutil command; no shell is involved.

if ~ispc
    options = javaArray('java.nio.file.LinkOption', 0);
    count = double(java.nio.file.Files.getAttribute( ...
        java.io.File(char(pathValue)).toPath(), 'unix:nlink', options));
else
    executable = fullfile(getenv('SystemRoot'), 'System32', 'fsutil.exe');
    assert(isfile(executable), 'Windows file-link inspection is unavailable.');
    command = javaArray('java.lang.String', 4);
    command(1) = java.lang.String(executable);
    command(2) = java.lang.String('hardlink');
    command(3) = java.lang.String('list');
    command(4) = java.lang.String(char(pathValue));
    builder = java.lang.ProcessBuilder(command);
    builder.redirectErrorStream(true);
    process = builder.start();
    processCleanup = onCleanup(@() process.destroy());
    scanner = java.util.Scanner(process.getInputStream(), 'UTF-8');
    scannerCleanup = onCleanup(@() scanner.close());
    scanner.useDelimiter('\A');
    output = "";
    if scanner.hasNext()
        output = string(char(scanner.next()));
    end
    status = process.waitFor();
    lines = strip(splitlines(output));
    lines(lines == "") = [];
    % Successful output is one volume-relative path per hard link. Reject
    % errors or unexpected output rather than assuming a single link.
    assert(status == 0 && ~isempty(lines) && all(startsWith(lines, "\")), ...
        'Windows file-link inspection did not return a valid link list.');
    count = numel(lines);
end
assert(isscalar(count) && isfinite(count) && count >= 1 && fix(count) == count, ...
    'The file-link count is invalid.');
end
