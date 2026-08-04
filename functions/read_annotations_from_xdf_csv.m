%% Function: read_annotations_from_xdf_csv
% This function extracts event annotations from an XDF-derived .csv file.
% It reads the 'annotation' column and returns all values (including duplicates)
% as a string column vector.
%
% INPUT:
%   - csvFile (string): Full path to the _events.csv file.
%
% OUTPUT:
%   - annotations (string array): A column vector of annotations (including duplicates).

function annotations = read_annotations_from_xdf_csv(csvFile)

%% Check if the specified event file exists
if ~isfile(csvFile)
    error('Event file not found: %s', csvFile);
end

%% Read the CSV file using readtable
% The file must include a column named "annotation"
try
    T = readtable(csvFile, 'TextType', 'string');
catch
    error('Failed to read CSV file: %s', csvFile);
end

%% Check that the "annotation" column exists
if ~ismember("annotation", T.Properties.VariableNames)
    error('The file %s does not contain a column named "annotation".', csvFile);
end

%% Extract and return the annotations column as a string vector
annotations = T.annotation;

%% Ensure the result is a column vector
if isrow(annotations)
    annotations = annotations';
end

end