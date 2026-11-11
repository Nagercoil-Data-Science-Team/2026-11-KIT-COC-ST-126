clc;
clear;
close all;
fprintf('============================================================\n');
fprintf('DDRE-33 DATA LOADING + PREPROCESSING\n');
fprintf('Project ID: 2026-11-KIT-COC-ST-126\n');
fprintf('============================================================\n\n');

%% ============================================================
% STEP 1 - DATASET LOCATION
% ============================================================
currentFolder = pwd;
fprintf('Current MATLAB folder:\n%s\n\n', currentFolder);
scenarioFolderList = dir(fullfile(currentFolder, '**', '1-Day Scenarios Actual'));
if isempty(scenarioFolderList)
    fprintf('The folder "1-Day Scenarios Actual" was not found.\n');
    selectedFolder = uigetdir(currentFolder, 'Select the DDRE-33 dataset folder');
    if isequal(selectedFolder, 0)
        error('Dataset folder selection was cancelled.');
    end
    currentFolder = selectedFolder;
    scenarioFolderList = dir(fullfile(currentFolder, '**', '1-Day Scenarios Actual'));
end
if isempty(scenarioFolderList)
    error('The folder "1-Day Scenarios Actual" was not found. Please select the correct DDRE-33 dataset folder.');
end
scenarioFolder = fullfile(scenarioFolderList(1).folder, scenarioFolderList(1).name);
datasetRoot = scenarioFolderList(1).folder;
fprintf('DDRE-33 dataset root:\n%s\n\n', datasetRoot);

%% ============================================================
% STEP 1.1 - FIND CSV SCENARIO FILES
% ============================================================
csvFiles = dir(fullfile(scenarioFolder, '**', '*.csv'));
numFiles = length(csvFiles);
fprintf('CSV files found: %d\n', numFiles);
if numFiles == 0
    error('No CSV files were found inside "1-Day Scenarios Actual". Check whether the archive has been extracted.');
end

%% ============================================================
% STEP 1.2 - LOAD ALL SCENARIOS
% ============================================================
scenarioData = cell(numFiles, 1);
scenarioNames = strings(numFiles, 1);
scenarioPaths = strings(numFiles, 1);
rowCounts = zeros(numFiles, 1);
columnCounts = zeros(numFiles, 1);
loadStatus = false(numFiles, 1);
for i = 1:numFiles
    filePath = fullfile(csvFiles(i).folder, csvFiles(i).name);
    scenarioNames(i) = string(csvFiles(i).name);
    scenarioPaths(i) = string(filePath);
    try
        opts = detectImportOptions(filePath);
        opts.VariableNamingRule = 'preserve';
        scenarioData{i} = readtable(filePath, opts);
        rowCounts(i) = height(scenarioData{i});
        columnCounts(i) = width(scenarioData{i});
        loadStatus(i) = true;
    catch ME
        warning('Unable to load: %s (%s)', csvFiles(i).name, ME.message);
        scenarioData{i} = [];
    end
end
successfulLoads = sum(loadStatus);
fprintf('Successfully loaded: %d | Failed: %d\n', successfulLoads, numFiles - successfulLoads);
if isempty(find(loadStatus, 1, 'first'))
    error('No scenario file was loaded successfully.');
end

%% ============================================================
% STEP 2 - DATA PREPROCESSING
% ============================================================
fprintf('\n============================================================\n');
fprintf('STEP 2 - DATA PREPROCESSING\n');
fprintf('============================================================\n');
expectedIntervals = 96;
intervalMinutes = 15;
expectedScenarios = 200;
preprocessedData = cell(numFiles, 1);
preprocessingSummary = table();
for i = 1:numFiles
    if ~loadStatus(i)
        continue;
    end
    T = scenarioData{i};
    originalRows = height(T);
    originalColumns = width(T);

    % empty values
    emptyCount = 0;
    for c = 1:width(T)
        columnData = T{:, c};
        if iscell(columnData)
            emptyCount = emptyCount + sum(cellfun(@(x) isempty(x) || (isstring(x) && strlength(x) == 0), columnData));
        elseif isstring(columnData)
            emptyCount = emptyCount + sum(strlength(columnData) == 0);
        end
    end

    % NaN / Inf count
    nanCount = 0;
    infCount = 0;
    for c = 1:width(T)
        columnData = T{:, c};
        if isnumeric(columnData)
            nanCount = nanCount + sum(isnan(columnData(:)));
            infCount = infCount + sum(isinf(columnData(:)));
        end
    end

    % numeric-like cell columns -> numeric
    for c = 1:width(T)
        columnData = T{:, c};
        if iscell(columnData)
            try
                convertedData = str2double(string(columnData));
                if any(~isnan(convertedData))
                    T{:, c} = convertedData;
                end
            catch
            end
        end
    end

    % PV / Wind columns
    lowerNames = lower(string(T.Properties.VariableNames));
    pvColumns = contains(lowerNames, 'pv') & ~contains(lowerNames, 'label') & ~contains(lowerNames, 'climate');
    windColumns = contains(lowerNames, 'wind') & ~contains(lowerNames, 'label') & ~contains(lowerNames, 'climate');

    % NaN and Inf handling
    for c = 1:width(T)
        columnData = T{:, c};
        if isnumeric(columnData)
            columnData(isinf(columnData)) = NaN;
            if any(isnan(columnData)) && sum(~isnan(columnData)) >= 2
                columnData = fillmissing(columnData, 'linear');
                columnData = fillmissing(columnData, 'nearest');
            end
            T{:, c} = columnData;
        end
    end

    % negative PV / wind
    negativePV = 0;
    negativeWind = 0;
    for c = 1:width(T)
        columnData = T{:, c};
        if isnumeric(columnData) && (pvColumns(c) || windColumns(c))
            neg = columnData < 0;
            if pvColumns(c)
                negativePV = negativePV + sum(neg);
            else
                negativeWind = negativeWind + sum(neg);
            end
            if any(neg)
                columnData(neg) = NaN;
                columnData = fillmissing(columnData, 'linear');
                columnData = fillmissing(columnData, 'nearest');
                T{:, c} = columnData;
            end
        end
    end

    % timestamp
    timestampFound = any(contains(lowerNames, 'time') | contains(lowerNames, 'date'));
    if ~timestampFound && height(T) == expectedIntervals
        T.Time = (datetime(2024,1,1,0,0,0):minutes(intervalMinutes):datetime(2024,1,1,23,45,0))';
    end
    finalRows = height(T);
    intervalStatus = (finalRows == expectedIntervals);

    % duplicate check against earlier scenarios (numeric columns)
    duplicateScenario = false;
    for j = 1:(i-1)
        if isempty(preprocessedData{j})
            continue;
        end
        Tprev = preprocessedData{j};
        commonNames = intersect(T.Properties.VariableNames, Tprev.Properties.VariableNames, 'stable');
        cu = [];
        pr = [];
        for cc = 1:length(commonNames)
            a = T.(commonNames{cc});
            b = Tprev.(commonNames{cc});
            if isnumeric(a) && isnumeric(b)
                cu = [cu, a(:)]; %#ok<AGROW>
                pr = [pr, b(:)]; %#ok<AGROW>
            end
        end
        if ~isempty(cu) && isequal(size(cu), size(pr)) && isequaln(cu, pr)
            duplicateScenario = true;
            break;
        end
    end
    preprocessedData{i} = T;
    newRow = table(i, scenarioNames(i), originalRows, finalRows, originalColumns, emptyCount, nanCount, infCount, negativePV, negativeWind, duplicateScenario, timestampFound, intervalStatus, 'VariableNames', {'Scenario_ID', 'File_Name', 'Original_Rows', 'Final_Rows', 'Columns', 'Empty_Values', 'NaN_Values', 'Inf_Values', 'Negative_PV', 'Negative_Wind', 'Duplicate_Scenario', 'Timestamp_Found', '96_Interval_Check'});
    preprocessingSummary = [preprocessingSummary; newRow]; %#ok<AGROW>
end

validScenarioCount = sum(loadStatus);
duplicateCount = sum(preprocessingSummary.Duplicate_Scenario);
duplicateRate = 100 * duplicateCount / max(validScenarioCount, 1);
intervalPassCount = sum(preprocessingSummary.('96_Interval_Check'));
fprintf('Loaded scenarios: %d | Duplicates: %d (%.2f %%)\n', validScenarioCount, duplicateCount, duplicateRate);
fprintf('Empty: %d | NaN: %d | Inf: %d | Negative PV: %d | Negative Wind: %d\n', sum(preprocessingSummary.Empty_Values), sum(preprocessingSummary.NaN_Values), sum(preprocessingSummary.Inf_Values), sum(preprocessingSummary.Negative_PV), sum(preprocessingSummary.Negative_Wind));
fprintf('Scenarios with 96 intervals: %d | without: %d\n', intervalPassCount, validScenarioCount - intervalPassCount);
if numFiles ~= expectedScenarios
    fprintf('NOTE: %d CSV files found but %d scenarios expected. Non-scenario, non-96-row and duplicate files are excluded in Step 3.\n', numFiles, expectedScenarios);
end

preprocessedMatFile = fullfile(datasetRoot, 'DDRE33_1Day_Actual_Preprocessed.mat');
save(preprocessedMatFile, 'preprocessedData', 'scenarioNames', 'scenarioPaths', 'preprocessingSummary', 'duplicateRate');
writetable(preprocessingSummary, fullfile(datasetRoot, 'DDRE33_Preprocessing_Summary.xlsx'));

%% ============================================================
% STEP 3 - K-MEANS SCENARIO GENERATION (K = 5)
% ============================================================
fprintf('\n============================================================\n');
fprintf('STEP 3 - K-MEANS SCENARIO GENERATION\n');
fprintf('============================================================\n');
numClusters = 5;
numReplicates = 50;
randomSeed = 126;
rng(randomSeed);
timeHours = (0:expectedIntervals-1)' * intervalMinutes / 60;
timeLabels = string(datetime(2024,1,1,0,0,0) + minutes((0:expectedIntervals-1)' * intervalMinutes), 'HH:mm');

validIdx = find(~cellfun(@isempty, preprocessedData));
refTable = preprocessedData{validIdx(1)};
refNames = string(refTable.Properties.VariableNames);
refLower = lower(refNames);
isGen = (contains(refLower, 'pv') | contains(refLower, 'wind')) & ~contains(refLower, 'label') & ~contains(refLower, 'climate');
isNum = false(size(isGen));
for c = 1:numel(refNames)
    isNum(c) = isnumeric(refTable{:, c});
end
genNames = refNames(isGen & isNum);
numGen = numel(genNames);
if numGen == 0
    error('No numeric PV/Wind generation column was found.');
end
isPVgen = contains(lower(genNames), 'pv');
isWindgen = ~isPVgen & contains(lower(genNames), 'wind');
fprintf('Generation profiles used: %d\n', numGen);
for g = 1:numGen
    fprintf('  %d. %s\n', g, genNames(g));
end

% feature matrix (excluding non-scenario files, non-96-row files and duplicates)
isDup = false(numFiles, 1);
isDup(preprocessingSummary.Scenario_ID) = preprocessingSummary.Duplicate_Scenario;
nonScenarioName = contains(lower(scenarioNames), ["summary", "readme", "metadata", "label", "info", "description"]);
numValid = numel(validIdx);
profilesAll = nan(expectedIntervals, numGen, numValid);
useScenario = false(numValid, 1);
for k = 1:numValid
    idx = validIdx(k);
    if nonScenarioName(idx)
        fprintf('Excluded (non-scenario file name): %s\n', scenarioNames(idx));
        continue;
    end
    if isDup(idx)
        fprintf('Excluded (duplicate scenario): %s\n', scenarioNames(idx));
        continue;
    end
    Tk = preprocessedData{idx};
    namesK = string(Tk.Properties.VariableNames);
    if height(Tk) ~= expectedIntervals || ~all(ismember(genNames, namesK))
        fprintf('Excluded (rows/columns mismatch): %s\n', scenarioNames(idx));
        continue;
    end
    Pk = zeros(expectedIntervals, numGen);
    for g = 1:numGen
        Pk(:, g) = double(Tk.(char(genNames(g))));
    end
    if any(isnan(Pk(:)))
        fprintf('Excluded (NaN remains): %s\n', scenarioNames(idx));
        continue;
    end
    profilesAll(:, :, k) = Pk;
    useScenario(k) = true;
end
keepIdx = validIdx(useScenario);
profiles = profilesAll(:, :, useScenario);
clusterScenarioNames = scenarioNames(keepIdx);
N = size(profiles, 3);
featureMatrix = zeros(N, expectedIntervals * numGen);
for k = 1:N
    Pk = profiles(:, :, k);
    featureMatrix(k, :) = Pk(:)';
end
fprintf('Scenarios used for K-Means (N): %d | Feature matrix: %d x %d\n', N, size(featureMatrix, 1), size(featureMatrix, 2));
if N ~= expectedScenarios
    fprintf('WARNING: N = %d but %d scenarios were expected.\n', N, expectedScenarios);
end
if N < numClusters
    error('Number of scenarios (%d) is smaller than K (%d).', N, numClusters);
end

% silhouette sweep (justification of K)
kList = 3:8;
silK = zeros(size(kList));
for q = 1:numel(kList)
    idq = kmeans(featureMatrix, kList(q), 'Start', 'plus', 'Replicates', 10, 'MaxIter', 500);
    silK(q) = mean(silhouette(featureMatrix, idq));
end
fprintf('Mean silhouette by K: %s\n', strjoin(compose('K=%d:%.3f', [kList; silK]'), ' | '));

rng(randomSeed);
[clusterIdxRaw, centroidsRaw, sumdRaw] = kmeans(featureMatrix, numClusters, 'Distance', 'sqeuclidean', 'Start', 'plus', 'Replicates', numReplicates, 'MaxIter', 1000, 'Display', 'off');
silhouetteValues = silhouette(featureMatrix, clusterIdxRaw);
meanSilhouette = mean(silhouetteValues);
fprintf('K-Means (K=%d): total within-cluster SS = %.4f | mean silhouette = %.4f (moderate cluster separation)\n', numClusters, sum(sumdRaw), meanSilhouette);

% re-order S1 (lowest) ... S5 (highest)
centroidProfilesRaw = zeros(expectedIntervals, numGen, numClusters);
totalAvgRaw = zeros(numClusters, 1);
for k = 1:numClusters
    centroidProfilesRaw(:, :, k) = reshape(centroidsRaw(k, :), expectedIntervals, numGen);
    totalAvgRaw(k) = mean(sum(centroidProfilesRaw(:, :, k), 2));
end
[~, sortOrder] = sort(totalAvgRaw, 'ascend');
oldToNew = zeros(numClusters, 1);
oldToNew(sortOrder) = (1:numClusters)';
clusterIdx = oldToNew(clusterIdxRaw);
centroids = centroidsRaw(sortOrder, :);
centroidProfiles = centroidProfilesRaw(:, :, sortOrder);
scenarioLabels = "S" + (1:numClusters)';

clusterCount = accumarray(clusterIdx, 1, [numClusters 1]);
clusterProb = clusterCount / N;
avgPerGen = zeros(numClusters, numGen);
totalPeak = zeros(numClusters, 1);
for k = 1:numClusters
    avgPerGen(k, :) = mean(centroidProfiles(:, :, k), 1);
    totalPeak(k) = max(sum(centroidProfiles(:, :, k), 2));
end
totalAvg = sum(avgPerGen, 2);
totalEnergy = totalAvg * expectedIntervals * intervalMinutes / 60;
pvAvg = sum(avgPerGen(:, isPVgen), 2);
pvShare = pvAvg ./ max(totalAvg, eps);

description = strings(numClusters, 1);
rangeTotal = max(totalAvg) - min(totalAvg);
for k = 1:numClusters
    if rangeTotal <= eps
        levelText = "Medium";
    elseif totalAvg(k) <= min(totalAvg) + rangeTotal / 3
        levelText = "Low";
    elseif totalAvg(k) >= min(totalAvg) + 2 * rangeTotal / 3
        levelText = "High";
    else
        levelText = "Medium";
    end
    if pvShare(k) > 0.6
        mixText = "solar dominant";
    elseif pvShare(k) < 0.4
        mixText = "wind dominant";
    else
        mixText = "mixed solar-wind";
    end
    description(k) = levelText + " renewable, " + mixText;
end

representativeIdx = zeros(numClusters, 1);
for k = 1:numClusters
    members = find(clusterIdx == k);
    d = sum((featureMatrix(members, :) - centroids(k, :)).^2, 2);
    [~, m] = min(d);
    representativeIdx(k) = members(m);
end
distToCentroid = sqrt(sum((featureMatrix - centroids(clusterIdx, :)).^2, 2));

genVarNames = matlab.lang.makeValidName(cellstr(genNames));
fprintf('\n%-10s %-12s %-12s\n', 'Scenario', 'N', 'Probability');
for k = 1:numClusters
    fprintf('%-10s %-12d %-12.4f | %s\n', scenarioLabels(k), clusterCount(k), clusterProb(k), description(k));
end
avgTable = array2table(avgPerGen, 'VariableNames', genVarNames);
centroidSummary = [table(scenarioLabels, 'VariableNames', {'Scenario'}), avgTable, table(totalAvg, totalPeak, totalEnergy, pvShare, 'VariableNames', {'Total_Renewable_Avg', 'Total_Renewable_Peak', 'Total_Renewable_Energy', 'PV_Share'})];
disp(centroidSummary);

clusterColors = lines(numClusters);
genColors = lines(numGen);

fig1 = figure('Name', 'K-Means Centroid Profiles', 'Color', 'w', 'Position', [50 50 1400 750]);
tl = tiledlayout(2, ceil((numClusters + 1) / 2), 'TileSpacing', 'compact', 'Padding', 'compact');
title(tl, sprintf('K-Means Representative Scenarios (K = %d, N = %d)', numClusters, N));
xlabel(tl, 'Time of day (hours)');
ylabel(tl, 'Generation');
for k = 1:numClusters
    nexttile;
    hold on;
    for g = 1:numGen
        plot(timeHours, centroidProfiles(:, g, k), 'LineWidth', 1.6, 'Color', genColors(g, :));
    end
    hold off;
    grid on;
    xlim([0 24]);
    title(sprintf('%s: %s (N=%d, P=%.3f)', scenarioLabels(k), description(k), clusterCount(k), clusterProb(k)), 'FontSize', 9, 'Interpreter', 'none');
    if k == 1
        legend(cellstr(genNames), 'Interpreter', 'none', 'Location', 'best', 'FontSize', 7);
    end
end
nexttile;
hold on;
for k = 1:numClusters
    plot(timeHours, sum(centroidProfiles(:, :, k), 2), 'LineWidth', 2, 'Color', clusterColors(k, :));
end
hold off;
grid on;
xlim([0 24]);
title('Total renewable generation of all scenarios', 'FontSize', 9);
legend(cellstr(scenarioLabels), 'Location', 'best', 'FontSize', 7);
saveFigureSafe(fig1, fullfile(datasetRoot, 'KMeans_Centroid_Profiles.png'));

fig2 = figure('Name', 'K-Means Average Generation', 'Color', 'w', 'Position', [100 100 1000 550]);
bar(avgPerGen);
grid on;
set(gca, 'XTickLabel', cellstr(scenarioLabels));
xlabel('Scenario');
ylabel('Average generation over 96 intervals');
title('Average generation of each source in each representative scenario');
legend(cellstr(genNames), 'Interpreter', 'none', 'Location', 'best');
saveFigureSafe(fig2, fullfile(datasetRoot, 'KMeans_Average_Generation.png'));

fig3 = figure('Name', 'K-Means Scenario Probability', 'Color', 'w', 'Position', [150 150 800 500]);
b = bar(100 * clusterProb);
b.FaceColor = 'flat';
b.CData = clusterColors;
grid on;
set(gca, 'XTickLabel', cellstr(scenarioLabels));
xlabel('Scenario');
ylabel('Probability (%)');
title('Scenario probability  P(Ck) = Nk / N');
ylim([0 max(100 * clusterProb) * 1.2]);
for k = 1:numClusters
    text(k, 100 * clusterProb(k), sprintf('%d (%.1f%%)', clusterCount(k), 100 * clusterProb(k)), 'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom');
end
saveFigureSafe(fig3, fullfile(datasetRoot, 'KMeans_Scenario_Probability.png'));

fig4 = figure('Name', 'K-Means PCA View', 'Color', 'w', 'Position', [200 200 850 600]);
[coeff, score, ~, ~, explained] = pca(featureMatrix);
if size(score, 2) >= 2
    centroidScore = (centroids - mean(featureMatrix, 1)) * coeff(:, 1:2);
    hold on;
    for k = 1:numClusters
        scatter(score(clusterIdx == k, 1), score(clusterIdx == k, 2), 36, clusterColors(k, :), 'filled', 'MarkerFaceAlpha', 0.7);
    end
    plot(centroidScore(:, 1), centroidScore(:, 2), 'kp', 'MarkerSize', 14, 'MarkerFaceColor', 'y');
    for k = 1:numClusters
        text(centroidScore(k, 1), centroidScore(k, 2), "  " + scenarioLabels(k), 'FontWeight', 'bold');
    end
    hold off;
    grid on;
    xlabel(sprintf('PC1 (%.1f %% variance)', explained(1)));
    ylabel(sprintf('PC2 (%.1f %% variance)', explained(2)));
    title('K-Means clusters of the daily scenarios (PCA projection, stars = centroids)');
    legend([cellstr(scenarioLabels); {'Centroids'}], 'Location', 'best');
end
saveFigureSafe(fig4, fullfile(datasetRoot, 'KMeans_PCA_Clusters.png'));

fig5 = figure('Name', 'K-Means Silhouette', 'Color', 'w', 'Position', [250 250 750 550]);
silhouette(featureMatrix, clusterIdx);
title(sprintf('Silhouette plot (mean = %.3f)', meanSilhouette));
saveFigureSafe(fig5, fullfile(datasetRoot, 'KMeans_Silhouette.png'));

summaryTable = [table(scenarioLabels, 'VariableNames', {'Scenario'}), avgTable, table(clusterProb, 'VariableNames', {'Probability'}), table(totalAvg, clusterCount, description, 'VariableNames', {'Total_Renewable_Avg', 'Num_Original_Scenarios', 'Suggested_Description'})];
profileMatrix = zeros(expectedIntervals, numClusters * (numGen + 1));
profileVarNames = cell(1, numClusters * (numGen + 1));
col = 0;
for k = 1:numClusters
    for g = 1:numGen
        col = col + 1;
        profileMatrix(:, col) = centroidProfiles(:, g, k);
        profileVarNames{col} = sprintf('S%d_%s', k, genVarNames{g});
    end
    col = col + 1;
    profileMatrix(:, col) = sum(centroidProfiles(:, :, k), 2);
    profileVarNames{col} = sprintf('S%d_Total_Renewable', k);
end
profileTable = [table((1:expectedIntervals)', timeLabels, timeHours, 'VariableNames', {'Interval', 'Time', 'Time_Hours'}), array2table(profileMatrix, 'VariableNames', profileVarNames)];
assignTable = table((1:N)', clusterScenarioNames(:), "S" + clusterIdx, distToCentroid, 'VariableNames', {'Scenario_ID', 'File_Name', 'Assigned_Scenario', 'Distance_To_Centroid'});
excelFile = fullfile(datasetRoot, 'Five_Representative_Scenarios.xlsx');
if exist(excelFile, 'file') == 2
    delete(excelFile);
end
writetable(summaryTable, excelFile, 'Sheet', 'Five_Scenarios');
writetable(profileTable, excelFile, 'Sheet', 'Profiles_96');
writetable(assignTable, excelFile, 'Sheet', 'Assignments');
save(fullfile(datasetRoot, 'DDRE33_KMeans_Results.mat'), 'featureMatrix', 'clusterIdx', 'centroids', 'centroidProfiles', 'clusterCount', 'clusterProb', 'genNames', 'summaryTable', 'profileTable', 'assignTable', 'description', 'meanSilhouette', 'silK', 'numClusters', 'randomSeed');

%% ============================================================
% STEP 4 - IEEE 33-BUS RENEWABLE INTEGRATION
% Power-flow engine: built-in backward/forward sweep (all steps).
% MATPOWER (if installed) is used only as an independent cross-check.
% ============================================================
fprintf('\n============================================================\n');
fprintf('STEP 4 - IEEE 33-BUS RENEWABLE INTEGRATION\n');
fprintf('============================================================\n');
numT = size(centroidProfiles, 1);
dtHours = intervalMinutes / 60;
scenarioLabels = "S" + (1:numClusters)';
genNames = string(genNames);

branchData = [1 2 0.0922 0.0470; 2 3 0.4930 0.2511; 3 4 0.3660 0.1864; 4 5 0.3811 0.1941; 5 6 0.8190 0.7070; 6 7 0.1872 0.6188; 7 8 0.7114 0.2351; 8 9 1.0300 0.7400; 9 10 1.0440 0.7400; 10 11 0.1966 0.0650; 11 12 0.3744 0.1238; 12 13 1.4680 1.1550; 13 14 0.5416 0.7129; 14 15 0.5910 0.5260; 15 16 0.7463 0.5450; 16 17 1.2890 1.7210; 17 18 0.7320 0.5740; 2 19 0.1640 0.1565; 19 20 1.5042 1.3554; 20 21 0.4095 0.4784; 21 22 0.7089 0.9373; 3 23 0.4512 0.3083; 23 24 0.8980 0.7091; 24 25 0.8960 0.7011; 6 26 0.2030 0.1034; 26 27 0.2842 0.1447; 27 28 1.0590 0.9337; 28 29 0.8042 0.7006; 29 30 0.5075 0.2585; 30 31 0.9744 0.9630; 31 32 0.3105 0.3619; 32 33 0.3410 0.5302];
loadPkW = [0 100 90 120 60 60 200 200 60 60 45 60 60 120 60 60 60 90 90 90 90 90 90 420 420 60 60 60 120 200 150 210 60]';
loadQkVAr = [0 60 40 80 30 20 100 100 20 20 30 35 35 80 10 20 20 40 40 40 40 40 50 200 200 25 25 20 70 600 70 100 40]';
baseMVA = 100;
baseKV = 12.66;
zBase = baseKV^2 / baseMVA;
netData.busNum = (1:33)';
netData.PdMW = loadPkW / 1000;
netData.QdMVAr = loadQkVAr / 1000;
netData.from = branchData(:, 1);
netData.to = branchData(:, 2);
netData.rPu = branchData(:, 3) / zBase;
netData.xPu = branchData(:, 4) / zBase;
netData.baseMVA = baseMVA;
numBus = numel(netData.busNum);
busNum = netData.busNum;
if any(netData.from >= netData.to)
    error('The built-in solver needs every branch to run from a lower to a higher bus number.');
end
engineName = "Built-in backward/forward sweep";
totalLoadMW = sum(netData.PdMW);
totalLoadMVAr = sum(netData.QdMVAr);
fprintf('Power-flow engine: %s | Total load: %.4f MW, %.4f MVAr\n', engineName, totalLoadMW, totalLoadMVAr);

% generation -> bus mapping
manualBusMap = [];
defaultPVBuses = [18 33];
defaultWindBuses = [22 25];
isPV = contains(lower(genNames), 'pv');
genBus = nan(1, numGen);
if ~isempty(manualBusMap)
    if numel(manualBusMap) ~= numGen
        error('manualBusMap must contain %d bus numbers.', numGen);
    end
    genBus = manualBusMap(:)';
else
    for g = 1:numGen
        tokens = regexp(char(genNames(g)), '\d+', 'match');
        if ~isempty(tokens)
            genBus(g) = str2double(tokens{end});
        end
    end
    if any(isnan(genBus)) || any(~ismember(genBus, busNum))
        if sum(isPV) ~= numel(defaultPVBuses) || sum(~isPV) ~= numel(defaultWindBuses)
            error('Cannot assign default buses: %d PV and %d wind profiles found. Set manualBusMap.', sum(isPV), sum(~isPV));
        end
        genBus(isPV) = defaultPVBuses;
        genBus(~isPV) = defaultWindBuses;
    end
end
busRow = zeros(1, numGen);
for g = 1:numGen
    r = find(busNum == genBus(g), 1);
    if isempty(r)
        error('Bus %d (profile "%s") does not exist. Set manualBusMap.', genBus(g), genNames(g));
    end
    busRow(g) = r;
end
for g = 1:numGen
    fprintf('  %-25s -> Bus %2d\n', genNames(g), genBus(g));
end

% unit conversion
generationUnitToMW = NaN;
totalProfiles = squeeze(sum(centroidProfiles, 2));
peakTotalDataset = max(totalProfiles(:));
if isnan(generationUnitToMW)
    if peakTotalDataset > 50
        generationUnitToMW = 0.001;
    else
        generationUnitToMW = 1;
    end
end
fprintf('Unit factor to MW: %.6f | Peak renewable = %.4f MW (%.1f %% of load)\n', generationUnitToMW, peakTotalDataset * generationUnitToMW, 100 * peakTotalDataset * generationUnitToMW / totalLoadMW);

% base case + MATPOWER cross-check
[baseVoltage, baseLossMW, baseSlackMW, baseOk] = solveNetworkPF(netData, netData.PdMW, netData.QdMVAr);
if ~baseOk
    error('The base-case power flow did not converge.');
end
[baseMinV, baseMinBusIdx] = min(baseVoltage);
baseLossMWh = baseLossMW * numT * dtHours;
fprintf('Base case (no renewables): Vmin = %.4f p.u. at bus %d | Loss = %.2f kW | Slack = %.4f MW\n', baseMinV, busNum(baseMinBusIdx), 1000 * baseLossMW, baseSlackMW);
if exist('runpf', 'file') == 2 && exist('case33bw', 'file') == 2
    try
        resMP = runpf(loadcase('case33bw'), mpoption('verbose', 0, 'out.all', 0));
        if resMP.success
            fprintf('MATPOWER cross-check (case33bw): max |dV| = %.2e p.u. | loss difference = %.3f kW\n', max(abs(resMP.bus(:, 8) - baseVoltage)), 1000 * abs(sum(real(get_losses(resMP))) - baseLossMW));
        end
    catch ME
        fprintf('MATPOWER cross-check skipped: %s\n', ME.message);
    end
else
    fprintf('MATPOWER not on the path: cross-check skipped (built-in solver used for all results).\n');
end

% 5 scenarios x 96 intervals
voltageAll = nan(numBus, numT, numClusters);
lossAllMW = nan(numT, numClusters);
slackAllMW = nan(numT, numClusters);
renewableMW = zeros(numT, numClusters);
failedCount = zeros(numClusters, 1);
for k = 1:numClusters
    for t = 1:numT
        PdNet = netData.PdMW;
        injectedMW = 0;
        for g = 1:numGen
            pMW = centroidProfiles(t, g, k) * generationUnitToMW;
            PdNet(busRow(g)) = PdNet(busRow(g)) - pMW;
            injectedMW = injectedMW + pMW;
        end
        renewableMW(t, k) = injectedMW;
        [vm, lossMW, slackMW, ok] = solveNetworkPF(netData, PdNet, netData.QdMVAr);
        if ok
            voltageAll(:, t, k) = vm;
            lossAllMW(t, k) = lossMW;
            slackAllMW(t, k) = slackMW;
        else
            failedCount(k) = failedCount(k) + 1;
        end
    end
end

minVoltage = zeros(numClusters, 1);
minVoltageBus = zeros(numClusters, 1);
minVoltageTime = strings(numClusters, 1);
minVoltageInterval = zeros(numClusters, 1);
maxVoltage = zeros(numClusters, 1);
dailyLossMWh = zeros(numClusters, 1);
lossReductionPct = zeros(numClusters, 1);
intervalsBelow095 = zeros(numClusters, 1);
intervalsAbove105 = zeros(numClusters, 1);
reverseFlowIntervals = zeros(numClusters, 1);
avgRenewableMW = zeros(numClusters, 1);
peakRenewableMW = zeros(numClusters, 1);
avgPenetrationPct = zeros(numClusters, 1);
for k = 1:numClusters
    vSc = voltageAll(:, :, k);
    [mv, linearIdx] = min(vSc(:));
    [bIdx, tIdx] = ind2sub(size(vSc), linearIdx);
    minVoltage(k) = mv;
    minVoltageBus(k) = busNum(bIdx);
    minVoltageInterval(k) = tIdx;
    minVoltageTime(k) = timeLabels(tIdx);
    maxVoltage(k) = max(vSc(:));
    dailyLossMWh(k) = sum(lossAllMW(:, k), 'omitnan') * dtHours;
    lossReductionPct(k) = 100 * (baseLossMWh - dailyLossMWh(k)) / baseLossMWh;
    intervalsBelow095(k) = sum(min(vSc, [], 1) < 0.95);
    intervalsAbove105(k) = sum(max(vSc, [], 1) > 1.05);
    reverseFlowIntervals(k) = sum(slackAllMW(:, k) < 0);
    avgRenewableMW(k) = mean(renewableMW(:, k));
    peakRenewableMW(k) = max(renewableMW(:, k));
    avgPenetrationPct(k) = 100 * avgRenewableMW(k) / totalLoadMW;
end
expectedLossMWh = sum(clusterProb(:) .* dailyLossMWh);
expectedLossReductionPct = 100 * (baseLossMWh - expectedLossMWh) / baseLossMWh;
expectedMinVoltage = sum(clusterProb(:) .* minVoltage);

summaryIntegration = table(scenarioLabels, clusterCount(:), clusterProb(:), avgRenewableMW, peakRenewableMW, avgPenetrationPct, minVoltage, minVoltageBus, minVoltageTime, maxVoltage, 1000 * dailyLossMWh, lossReductionPct, intervalsBelow095, intervalsAbove105, reverseFlowIntervals, 'VariableNames', {'Scenario', 'N_Original', 'Probability', 'Avg_Renewable_MW', 'Peak_Renewable_MW', 'Avg_Penetration_pct', 'Min_Voltage_pu', 'Min_Voltage_Bus', 'Min_Voltage_Time', 'Max_Voltage_pu', 'Daily_Loss_kWh', 'Loss_Reduction_pct', 'Intervals_Below_0p95', 'Intervals_Above_1p05', 'Reverse_Flow_Intervals'});
disp(summaryIntegration);
fprintf('Base daily loss: %.2f kWh | Expected daily loss: %.2f kWh | Expected loss reduction: %.2f %% | Expected Vmin: %.4f p.u. | Non-converged PFs: %d\n', 1000 * baseLossMWh, 1000 * expectedLossMWh, expectedLossReductionPct, expectedMinVoltage, sum(failedCount));

scenarioColors = lines(numClusters);
fig6 = figure('Name', 'Minimum Voltage', 'Color', 'w', 'Position', [60 60 1000 550]);
hold on;
for k = 1:numClusters
    plot(timeHours, squeeze(min(voltageAll(:, :, k), [], 1)), 'LineWidth', 1.8, 'Color', scenarioColors(k, :));
end
plot(timeHours, baseMinV * ones(numT, 1), 'k--', 'LineWidth', 1.5);
yline(0.95, 'r:', 'LineWidth', 1.2);
yline(1.05, 'r:', 'LineWidth', 1.2);
hold off;
grid on;
xlim([0 24]);
xlabel('Time of day (hours)');
ylabel('Minimum bus voltage (p.u.)');
title('Minimum voltage of the IEEE 33-bus system - 5 renewable scenarios');
legend([cellstr(scenarioLabels); {'Base case (no renewables)'}], 'Location', 'best');
saveFigureSafe(fig6, fullfile(datasetRoot, 'Integration_Min_Voltage.png'));

fig7 = figure('Name', 'Network Losses', 'Color', 'w', 'Position', [90 90 1000 550]);
hold on;
for k = 1:numClusters
    plot(timeHours, 1000 * lossAllMW(:, k), 'LineWidth', 1.8, 'Color', scenarioColors(k, :));
end
plot(timeHours, 1000 * baseLossMW * ones(numT, 1), 'k--', 'LineWidth', 1.5);
hold off;
grid on;
xlim([0 24]);
xlabel('Time of day (hours)');
ylabel('Active power loss (kW)');
title('Network active power loss - 5 renewable scenarios');
legend([cellstr(scenarioLabels); {'Base case (no renewables)'}], 'Location', 'best');
saveFigureSafe(fig7, fullfile(datasetRoot, 'Integration_Losses.png'));

fig8 = figure('Name', 'Voltage Profile Worst Interval', 'Color', 'w', 'Position', [120 120 1000 550]);
hold on;
for k = 1:numClusters
    plot(busNum, voltageAll(:, minVoltageInterval(k), k), '-o', 'LineWidth', 1.4, 'MarkerSize', 4, 'Color', scenarioColors(k, :));
end
plot(busNum, baseVoltage, 'k--', 'LineWidth', 1.5);
yline(0.95, 'r:', 'LineWidth', 1.2);
hold off;
grid on;
xlabel('Bus number');
ylabel('Voltage magnitude (p.u.)');
title('Voltage profile at the lowest-voltage interval of each scenario');
legend([cellstr(scenarioLabels); {'Base case (no renewables)'}], 'Location', 'best');
saveFigureSafe(fig8, fullfile(datasetRoot, 'Integration_Voltage_Profile.png'));

fig9 = figure('Name', 'Loss Energy and Substation Power', 'Color', 'w', 'Position', [150 150 1200 500]);
tiledlayout(1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
nexttile;
lossBars = bar([1000 * baseLossMWh; 1000 * dailyLossMWh]);
lossBars.FaceColor = 'flat';
lossBars.CData = [0 0 0; scenarioColors];
grid on;
set(gca, 'XTickLabel', [{'Base'}; cellstr(scenarioLabels)]);
ylabel('Daily loss energy (kWh)');
title('Daily network loss energy');
nexttile;
hold on;
for k = 1:numClusters
    plot(timeHours, slackAllMW(:, k), 'LineWidth', 1.8, 'Color', scenarioColors(k, :));
end
plot(timeHours, baseSlackMW * ones(numT, 1), 'k--', 'LineWidth', 1.5);
hold off;
grid on;
xlim([0 24]);
xlabel('Time of day (hours)');
ylabel('Substation active power (MW)');
title('Power drawn from the substation');
legend([cellstr(scenarioLabels); {'Base case'}], 'Location', 'best');
saveFigureSafe(fig9, fullfile(datasetRoot, 'Integration_Loss_and_Substation_Power.png'));

worstVoltageTable = table(busNum, baseVoltage, 'VariableNames', {'Bus', 'Base_Case'});
for k = 1:numClusters
    worstVoltageTable.(char(scenarioLabels(k))) = voltageAll(:, minVoltageInterval(k), k);
end
minVoltageSeries = squeeze(min(voltageAll, [], 1));
minVoltageTable = [table((1:numT)', timeLabels, timeHours, 'VariableNames', {'Interval', 'Time', 'Time_Hours'}), array2table(minVoltageSeries, 'VariableNames', cellstr(scenarioLabels))];
lossTable = [table((1:numT)', timeLabels, 'VariableNames', {'Interval', 'Time'}), array2table(1000 * lossAllMW, 'VariableNames', cellstr(scenarioLabels))];
slackTable = [table((1:numT)', timeLabels, 'VariableNames', {'Interval', 'Time'}), array2table(slackAllMW, 'VariableNames', cellstr(scenarioLabels))];
renewableTable = [table((1:numT)', timeLabels, 'VariableNames', {'Interval', 'Time'}), array2table(renewableMW, 'VariableNames', cellstr(scenarioLabels))];
integrationExcel = fullfile(datasetRoot, 'Renewable_Integration_Results.xlsx');
if exist(integrationExcel, 'file') == 2
    delete(integrationExcel);
end
writetable(summaryIntegration, integrationExcel, 'Sheet', 'Summary');
writetable(minVoltageTable, integrationExcel, 'Sheet', 'Min_Voltage_96');
writetable(lossTable, integrationExcel, 'Sheet', 'Loss_kW_96');
writetable(slackTable, integrationExcel, 'Sheet', 'Substation_MW_96');
writetable(renewableTable, integrationExcel, 'Sheet', 'Renewable_MW_96');
writetable(worstVoltageTable, integrationExcel, 'Sheet', 'Bus_Voltage_Worst');
save(fullfile(datasetRoot, 'DDRE33_Integration_Results.mat'), 'engineName', 'voltageAll', 'lossAllMW', 'slackAllMW', 'renewableMW', 'summaryIntegration', 'genBus', 'genNames', 'generationUnitToMW', 'baseVoltage', 'baseLossMW', 'baseSlackMW', 'clusterProb');

%% ============================================================
% STEP 5 - ADAPTIVE SPSA-QAOA OPTIMIZATION
% J = w1*Ploss/Ploss0 + w2*VD/VD0 + w3*Cop/Cop0 + w4*Ccurt
% J_QUBO = J + l1*P_voltage + l2*P_branch + l3*P_balance
% ============================================================
fprintf('\n============================================================\n');
fprintf('STEP 5 - ADAPTIVE SPSA-QAOA OPTIMIZATION\n');
fprintf('============================================================\n');
numK = size(centroidProfiles, 3);
scColors = lines(numK);

objWeights = [0.30 0.25 0.25 0.20];
penaltyLambda = [2000 20 20];
% Voltage limits. The no-renewable base case has Vmin ~0.913 p.u. (below 0.95) at nominal
% load, and PV is zero at night, so 0.95 cannot be met in those intervals with the available
% controls. 0.90-1.10 p.u. is the usual 33-bus operating range; change to [0.95 1.05] if required.
vLimits = [0.90 1.10];
vTol = 1e-6;
gridPrice = 60;
renewablePrice = 10;
battWearPrice = 15;
capSwitchPrice = 0.5;
battRatedMW = 0.4;
battBusNo = 18;
capBusNo = 30;
capBusNo2 = 14;
capStepMVAr = 0.3;
capStepMVAr2 = 0.2;
branchRatingFactor = 1.25;

bitsPerGen = 2;
if 2 * numGen + 5 > 13
    bitsPerGen = 1;
end
numQubits = numGen * bitsPerGen + 5;
if numQubits > 14
    error('Too many qubits (%d) for the statevector simulation.', numQubits);
end
numStates = 2^numQubits;
qaoaDepth = 3;
shots = 2000;
finalShots = 4096;
spsaIter = 60;
nRuns = 10;
numCandidates = 30;
fixedGamma = 0.5;
fixedBeta = 0.3;
saSteps = 2000;
saT0 = 0.3;
saTend = 1e-3;
cfgStd = struct('a', 0.3, 'c', 0.2, 'A', 0.1 * spsaIter, 'alpha', 0.602, 'gamma', 0.101, 'adaptive', false, 'stepTarget', 0, 'maxStep', 0.5);
cfgAda = struct('a', 0.3, 'c', 0.2, 'A', 0.1 * spsaIter, 'alpha', 0.602, 'gamma', 0.101, 'adaptive', true, 'stepTarget', 0.25, 'maxStep', 0.5);
methodNames = {'Classical SA (QUBO)', 'QAOA fixed (0.5, 0.3)', 'SPSA-QAOA', 'Adaptive SPSA-QAOA'};
numMethods = numel(methodNames);

P = struct();
P.nBus = numBus;
P.numT = numT;
P.numGen = numGen;
P.dtHours = dtHours;
P.baseMVA = netData.baseMVA;
P.parent = zeros(numBus, 1);
P.parent(netData.to) = netData.from;
P.zBr = zeros(numBus, 1);
P.zBr(netData.to) = netData.rPu + 1i * netData.xPu;
P.rBr = real(P.zBr);
P.xBr = imag(P.zBr);
P.Pd0 = netData.PdMW(:);
P.Qd0 = netData.QdMVAr(:);
P.busRow = busRow(:)';
P.genMW = centroidProfiles * generationUnitToMW;
P.bpg = bitsPerGen;
P.dispLevels = linspace(0, 1, 2^bitsPerGen);
P.battBit = numGen * bitsPerGen + 1;
P.capBits = numGen * bitsPerGen + (2:3);
P.capBits2 = numGen * bitsPerGen + (4:5);
P.capStepMVAr = capStepMVAr;
P.capStepMVAr2 = capStepMVAr2;
P.battRatedMW = battRatedMW;
P.battRow = find(busNum == battBusNo, 1);
P.capRow = find(busNum == capBusNo, 1);
P.capRow2 = find(busNum == capBusNo2, 1);
if isempty(P.battRow) || isempty(P.capRow) || isempty(P.capRow2)
    error('Battery or capacitor bus does not exist in the network.');
end
P.w = objWeights;
P.lam = penaltyLambda;
P.vLo = vLimits(1);
P.vHi = vLimits(2);
P.vTol = vTol;
P.cGrid = gridPrice;
P.cRen = renewablePrice;
P.cBatt = battWearPrice;
P.cCap = capSwitchPrice;
P.tSample = 1:12:numT;

[Vb0, Ib0, okb0] = radialPF(P, P.Pd0, P.Qd0);
if ~okb0
    error('Base-case radial power flow did not converge in Step 5.');
end
P.ratingPu = max(branchRatingFactor * abs(Ib0), 0.25 * max(abs(Ib0)));
P.refLoss = baseLossMW;
P.refVD = sum(abs(baseVoltage - 1));
P.refCost = gridPrice * baseSlackMW;
baseVSI = minVSI(Vb0, Ib0, P);

P.battSched = zeros(numT, numK);
for k = 1:numK
    rk = renewableMW(:, k);
    below = rk < mean(rk);
    nd = sum(below);
    nc = numT - nd;
    sched = zeros(numT, 1);
    if nd > 0 && nc > 0
        sched(below) = 1;
        sched(~below) = -nd / nc;
        sched = sched / max(abs(sched));
    end
    P.battSched(:, k) = sched;
end

fprintf('Qubits: %d (dispatch %d bits/profile, battery 1, capacitor bus %d 2 bits x %.2f MVAr, capacitor bus %d 2 bits x %.2f MVAr)\n', numQubits, bitsPerGen, capBusNo, capStepMVAr, capBusNo2, capStepMVAr2);
fprintf('Dispatch levels: %s | QAOA depth p = %d | SPSA iterations = %d | runs = %d\n', mat2str(P.dispLevels, 3), qaoaDepth, spsaIter, nRuns);
fprintf('Voltage limits: %.2f - %.2f p.u. | Base VSI = %.4f\n', vLimits(1), vLimits(2), baseVSI);
if baseMinV < vLimits(1)
    fprintf('WARNING: base-case Vmin %.4f is below the lower limit %.2f.\n', baseMinV, vLimits(1));
end

%% ------------------------------------------------------------
% STEP 5.2 - QUBO construction
% ------------------------------------------------------------
Xall = mod(floor((0:numStates-1)' ./ 2.^(0:numQubits-1)), 2);
Jsample = zeros(numStates, numK);
enumTime = zeros(numK, 1);
for k = 1:numK
    tic;
    for s = 1:numStates
        Rs = evalConfig(Xall(s, :), k, P.tSample, P);
        Jsample(s, k) = Rs.J;
    end
    enumTime(k) = toc;
end
pairIdx = nchoosek(1:numQubits, 2);
Phi = [ones(numStates, 1), Xall, Xall(:, pairIdx(:, 1)) .* Xall(:, pairIdx(:, 2))];
Qmat = zeros(numQubits, numQubits, numK);
c0 = zeros(numK, 1);
Equbo = zeros(numStates, numK);
Es = zeros(numStates, numK);
qfitR2 = zeros(numK, 1);
qfitSpearman = zeros(numK, 1);
quboMinMatchesTrue = false(numK, 1);
for k = 1:numK
    coef = Phi \ Jsample(:, k);
    c0(k) = coef(1);
    U = zeros(numQubits);
    U(1:numQubits+1:end) = coef(2:numQubits+1);
    for pp = 1:size(pairIdx, 1)
        U(pairIdx(pp, 1), pairIdx(pp, 2)) = coef(numQubits + 1 + pp);
    end
    Qmat(:, :, k) = U;
    Equbo(:, k) = c0(k) + sum((Xall * U) .* Xall, 2);
    res = Jsample(:, k) - Equbo(:, k);
    qfitR2(k) = 1 - sum(res.^2) / max(sum((Jsample(:, k) - mean(Jsample(:, k))).^2), eps);
    qfitSpearman(k) = corr(Equbo(:, k), Jsample(:, k), 'Type', 'Spearman');
    rangeE = max(Equbo(:, k)) - min(Equbo(:, k));
    Es(:, k) = (Equbo(:, k) - min(Equbo(:, k))) / max(rangeE, eps);
    [~, sq] = min(Equbo(:, k));
    [~, st] = min(Jsample(:, k));
    quboMinMatchesTrue(k) = (sq == st);
    fprintf('%s: enumeration %.1f s | QUBO R^2 = %.4f | Spearman = %.4f | QUBO min = true min: %d\n', scenarioLabels(k), enumTime(k), qfitR2(k), qfitSpearman(k), quboMinMatchesTrue(k));
end

%% ------------------------------------------------------------
% STEP 5.3 / 5.4 - QAOA + adaptive SPSA (candidates validated by AC PF over 96 intervals)
% ------------------------------------------------------------
validCache = cell(numStates, numK);
unoptBits = [ones(1, numGen * bitsPerGen), 0, 0, 0, 0, 0];
Runopt = cell(numK, 1);
for k = 1:numK
    Runopt{k} = evalConfig(unoptBits, k, 1:numT, P);
end

Jexh = zeros(numK, 1);
for k = 1:numK
    [~, ordJ] = sort(Jsample(:, k));
    col = validCache(:, k);
    [sExh, col] = validateAndSelect(ordJ(1:numCandidates), col, Xall, k, P);
    validCache(:, k) = col;
    Jexh(k) = col{sExh}.J;
end

JRuns = nan(nRuns, numMethods, numK);
JobjRuns = nan(nRuns, numMethods, numK);
timeRuns = nan(nRuns, numMethods, numK);
stateRuns = nan(nRuns, numMethods, numK);
feasRuns = false(nRuns, numMethods, numK);
convHist = nan(spsaIter + 1, nRuns, 2, numK);
for k = 1:numK
    Esk = Es(:, k);
    col = validCache(:, k);
    for r = 1:nRuns
        rng(randomSeed + 1000 * k + r);
        theta0 = [pi * rand(qaoaDepth, 1); (pi / 2) * rand(qaoaDepth, 1)];
        for m = 1:numMethods
            tic;
            switch m
                case 1
                    visited = runSA(Esk, numQubits, saSteps, saT0, saTend);
                    u = unique(visited);
                    [~, o] = sort(Esk(u));
                    cands = u(o(1:min(numCandidates, numel(u))));
                case 2
                    thFixed = [fixedGamma * ones(qaoaDepth, 1); fixedBeta * ones(qaoaDepth, 1)];
                    cands = measureCandidates(thFixed, Esk, numQubits, qaoaDepth, finalShots, numCandidates);
                case 3
                    outS = runSPSA(Esk, numQubits, qaoaDepth, theta0, spsaIter, shots, cfgStd);
                    cands = measureCandidates(outS.theta, Esk, numQubits, qaoaDepth, finalShots, numCandidates);
                    convHist(:, r, 1, k) = outS.hist;
                case 4
                    outA = runSPSA(Esk, numQubits, qaoaDepth, theta0, spsaIter, shots, cfgAda);
                    cands = measureCandidates(outA.theta, Esk, numQubits, qaoaDepth, finalShots, numCandidates);
                    convHist(:, r, 2, k) = outA.hist;
            end
            timeRuns(r, m, k) = toc;
            [sB, col] = validateAndSelect(cands(:), col, Xall, k, P);
            Rv = col{sB};
            stateRuns(r, m, k) = sB;
            JRuns(r, m, k) = Rv.J;
            JobjRuns(r, m, k) = Rv.Jobj;
            feasRuns(r, m, k) = Rv.feasible;
        end
    end
    validCache(:, k) = col;
    fprintf('Scenario %s: mean J | SA %.4f | QAOA-fixed %.4f | SPSA %.4f | Adaptive %.4f | Reference %.4f | Feasible %% (Adaptive) = %.0f\n', scenarioLabels(k), mean(JRuns(:, 1, k)), mean(JRuns(:, 2, k)), mean(JRuns(:, 3, k)), mean(JRuns(:, 4, k)), Jexh(k), 100 * mean(feasRuns(:, 4, k)));
end

%% ------------------------------------------------------------
% STEP 5.5 - Optimal solution extraction + AC power-flow check
% ------------------------------------------------------------
bestState = zeros(numK, 1);
bestRun = zeros(numK, 1);
Rbest = cell(numK, 1);
bitString = strings(numK, 1);
levelText = strings(numK, 1);
battStatus = zeros(numK, 1);
capMVAr = zeros(numK, 1);
pfText = ["FAIL", "PASS"];
chkVolt = false(numK, 1);
chkBranch = false(numK, 1);
chkBalance = false(numK, 1);
chkGen = false(numK, 1);
for k = 1:numK
    Jk = JRuns(:, 4, k);
    pool = find(feasRuns(:, 4, k));
    if isempty(pool)
        pool = (1:nRuns)';
    end
    [~, mi] = min(Jk(pool));
    bestRun(k) = pool(mi);
    bestState(k) = stateRuns(bestRun(k), 4, k);
    Rbest{k} = validCache{bestState(k), k};
    dk = Rbest{k}.dec;
    bitString(k) = string(char(Xall(bestState(k), :) + '0'));
    levelText(k) = string(strtrim(sprintf('%.0f%% ', 100 * dk.level)));
    battStatus(k) = dk.batt;
    capMVAr(k) = dk.Qcap + dk.Qcap2;
    chkVolt(k) = Rbest{k}.nViolV == 0;
    chkBranch(k) = Rbest{k}.maxLoading <= 1 + 1e-9;
    chkBalance(k) = Rbest{k}.minSlack >= -1e-9;
    chkGen(k) = all(dk.level <= 1) && abs(dk.batt * battRatedMW) <= battRatedMW + 1e-12;
end
J_Final = zeros(numK, 1);
for k = 1:numK
    J_Final(k) = Rbest{k}.J;
end
sol5 = table(scenarioLabels, bitString, levelText, battStatus, capMVAr, J_Final, 'VariableNames', {'Scenario', 'Bitstring', 'Dispatch_Levels', 'Battery_On', 'Capacitor_Total_MVAr', 'J_Final'});
disp(sol5);
fprintf('%-9s %-9s %-9s %-9s %-9s | %-8s %-8s %-9s %-10s\n', 'Scenario', 'Voltage', 'Branch', 'Balance', 'Generator', 'Vmin', 'Vmax', 'MaxLoad', 'MinSlackMW');
for k = 1:numK
    fprintf('%-9s %-9s %-9s %-9s %-9s | %-8.4f %-8.4f %-9.3f %-10.4f\n', scenarioLabels(k), pfText(double(chkVolt(k)) + 1), pfText(double(chkBranch(k)) + 1), pfText(double(chkBalance(k)) + 1), pfText(double(chkGen(k)) + 1), Rbest{k}.Vmin, Rbest{k}.Vmax, Rbest{k}.maxLoading, Rbest{k}.minSlack);
end
if any(~(chkVolt & chkBranch & chkBalance & chkGen))
    fprintf('NOTE: at least one scenario has no fully feasible candidate; the least-violation candidate was reported as INFEASIBLE, not as a feasible optimum.\n');
end

%% ============================================================
% STEP 6 - RESULTS (unoptimized Step-4 operation vs proposed)
% ============================================================
fprintf('\n============================================================\n');
fprintf('STEP 6 - RESULTS FOR ALL FIVE SCENARIOS\n');
fprintf('============================================================\n');
lossU = zeros(numK, 1); lossP = zeros(numK, 1);
vdU = zeros(numK, 1); vdP = zeros(numK, 1);
vsiU = zeros(numK, 1); vsiP = zeros(numK, 1);
reuU = zeros(numK, 1); reuP = zeros(numK, 1);
costU = zeros(numK, 1); costP = zeros(numK, 1);
curtU = zeros(numK, 1); curtP = zeros(numK, 1);
vminU = zeros(numK, 1); vminP = zeros(numK, 1);
for k = 1:numK
    Ru = Runopt{k};
    Rp = Rbest{k};
    lossU(k) = 1000 * Ru.lossMW;  lossP(k) = 1000 * Rp.lossMW;
    vdU(k) = Ru.VD;               vdP(k) = Rp.VD;
    vsiU(k) = Ru.VSImin;          vsiP(k) = Rp.VSImin;
    reuU(k) = Ru.REU;             reuP(k) = Rp.REU;
    costU(k) = Ru.cost;           costP(k) = Rp.cost;
    curtU(k) = 100 * Ru.curt;     curtP(k) = 100 * Rp.curt;
    vminU(k) = Ru.Vmin;           vminP(k) = Rp.Vmin;
end
res6 = table(scenarioLabels, clusterProb(:), lossU, lossP, vdU, vdP, vsiU, vsiP, reuU, reuP, costU, costP, curtU, curtP, vminU, vminP, 'VariableNames', {'Scenario', 'Probability', 'Ploss_kW_Unopt', 'Ploss_kW_Prop', 'VD_pu_Unopt', 'VD_pu_Prop', 'VSImin_Unopt', 'VSImin_Prop', 'REU_pct_Unopt', 'REU_pct_Prop', 'Cost_per_h_Unopt', 'Cost_per_h_Prop', 'Curtail_pct_Unopt', 'Curtail_pct_Prop', 'Vmin_Unopt', 'Vmin_Prop'});
disp(res6);
pw = clusterProb(:);
fprintf('Probability-weighted expected values (Unoptimized -> Proposed):\n');
fprintf('6.1 Active power loss (kW): %.2f -> %.2f (%.2f %% reduction)\n', sum(pw .* lossU), sum(pw .* lossP), 100 * (sum(pw .* lossU) - sum(pw .* lossP)) / sum(pw .* lossU));
fprintf('6.2 Voltage deviation VD = sum over buses |V-1| (p.u.), mean over 96 intervals: %.4f -> %.4f\n', sum(pw .* vdU), sum(pw .* vdP));
fprintf('6.3 Min VSI (Chakravorty-Das): %.4f -> %.4f\n', sum(pw .* vsiU), sum(pw .* vsiP));
fprintf('6.4 Renewable utilization (%%): %.2f -> %.2f\n', sum(pw .* reuU), sum(pw .* reuP));
fprintf('6.5 Operating cost ($/h): %.2f -> %.2f\n', sum(pw .* costU), sum(pw .* costP));
fprintf('6.6 Renewable curtailment (%%): %.2f -> %.2f\n', sum(pw .* curtU), sum(pw .* curtP));

%% ============================================================
% STEP 7 - ALGORITHM PERFORMANCE
% QAOA is a classical statevector simulation; run times are not evidence of quantum advantage.
% ============================================================
fprintf('\n============================================================\n');
fprintf('STEP 7 - ALGORITHM PERFORMANCE (classical simulation of QAOA; no quantum advantage claimed)\n');
fprintf('============================================================\n');
convMean = zeros(spsaIter + 1, 2, numK);
convStd = zeros(spsaIter + 1, 2, numK);
convIter = zeros(2, numK);
for k = 1:numK
    for mi = 1:2
        convMean(:, mi, k) = mean(convHist(:, :, mi, k), 2);
        convStd(:, mi, k) = std(convHist(:, :, mi, k), 0, 2);
        h = convMean(:, mi, k);
        tolE = h(end) + 0.05 * (h(1) - h(end));
        idxC = find(h <= tolE, 1, 'first');
        convIter(mi, k) = idxC - 1;
    end
end
conv7 = table(scenarioLabels, convIter(1, :)', convIter(2, :)', squeeze(convMean(end, 1, :)), squeeze(convMean(end, 2, :)), 'VariableNames', {'Scenario', 'Iter95_SPSA', 'Iter95_Adaptive', 'FinalE_SPSA', 'FinalE_Adaptive'});
disp(conv7);

timeMean = squeeze(mean(timeRuns, 1))';
timeTable = table(scenarioLabels, enumTime, timeMean(:, 1), timeMean(:, 2), timeMean(:, 3), timeMean(:, 4), 'VariableNames', {'Scenario', 'Exhaustive_AC_PF_s', 'SA_s', 'QAOA_fixed_s', 'SPSA_QAOA_s', 'Adaptive_SPSA_QAOA_s'});
disp(timeTable);

JmeanMat = squeeze(mean(JRuns, 1))';
JstdMat = squeeze(std(JRuns, 0, 1))';
JunoptVec = zeros(numK, 1);
for k = 1:numK
    JunoptVec(k) = Runopt{k}.J;
end
jTable = table(scenarioLabels, JunoptVec, Jexh, JmeanMat(:, 1), JmeanMat(:, 2), JmeanMat(:, 3), JmeanMat(:, 4), 'VariableNames', {'Scenario', 'J_Unoptimized', 'J_Reference_TopQUBO', 'J_SA', 'J_QAOA_fixed', 'J_SPSA_QAOA', 'J_Adaptive_SPSA_QAOA'});
disp(jTable);

impTable = table(scenarioLabels, ...
    100 * (JunoptVec - JmeanMat(:, 4)) ./ max(abs(JunoptVec), eps), ...
    100 * (JmeanMat(:, 1) - JmeanMat(:, 4)) ./ max(abs(JmeanMat(:, 1)), eps), ...
    100 * (JmeanMat(:, 2) - JmeanMat(:, 4)) ./ max(abs(JmeanMat(:, 2)), eps), ...
    100 * (JmeanMat(:, 3) - JmeanMat(:, 4)) ./ max(abs(JmeanMat(:, 3)), eps), ...
    100 * (JmeanMat(:, 4) - Jexh) ./ max(abs(Jexh), eps), ...
    'VariableNames', {'Scenario', 'Improve_vs_Unoptimized_pct', 'Improve_vs_SA_pct', 'Improve_vs_QAOA_fixed_pct', 'Improve_vs_SPSA_QAOA_pct', 'Gap_to_Reference_pct'});
disp(impTable);

stab7 = table();
for k = 1:numK
    for m = 1:numMethods
        xk = JRuns(:, m, k);
        stab7 = [stab7; table(scenarioLabels(k), string(methodNames{m}), mean(xk), std(xk), min(xk), max(xk), 100 * mean(xk <= Jexh(k) + 1e-9), 100 * mean(feasRuns(:, m, k)), 'VariableNames', {'Scenario', 'Method', 'Mean_J', 'Std_J', 'Best_J', 'Worst_J', 'Hit_Reference_pct', 'Feasible_pct'})]; %#ok<AGROW>
    end
end
disp(stab7);

%% ------------------------------------------------------------
% STEP 5-7 plots
% ------------------------------------------------------------
set(groot, 'defaultAxesFontName', 'Times New Roman', 'defaultAxesFontWeight', 'bold', 'defaultAxesFontSize', 18, 'defaultTextFontName', 'Times New Roman', 'defaultTextFontWeight', 'bold', 'defaultTextFontSize', 18, 'defaultLegendFontName', 'Times New Roman', 'defaultLegendFontSize', 18, 'defaultColorbarFontName', 'Times New Roman');
fig10 = figure('Name', 'SPSA Convergence', 'Color', 'w', 'Position', [40 40 1400 750]);
tl10 = tiledlayout(2, ceil((numK + 1) / 2), 'TileSpacing', 'compact', 'Padding', 'compact');
title(tl10, 'Convergence of the QAOA expectation value (normalized, mean +/- std)');
xlabel(tl10, 'SPSA iteration');
ylabel(tl10, 'Normalized expected cost');
xIt = (0:spsaIter)';
cvColors = [0.85 0.33 0.10; 0.00 0.45 0.74];
for k = 1:numK
    nexttile;
    hold on;
    for mi = 1:2
        mu = convMean(:, mi, k);
        sd = convStd(:, mi, k);
        fill([xIt; flipud(xIt)], [mu - sd; flipud(mu + sd)], cvColors(mi, :), 'FaceAlpha', 0.15, 'EdgeColor', 'none', 'HandleVisibility', 'off');
        plot(xIt, mu, 'LineWidth', 1.8, 'Color', cvColors(mi, :));
    end
    hold off;
    grid on;
    title(char(scenarioLabels(k)));
    if k == 1
        legend({'SPSA-QAOA', 'Adaptive SPSA-QAOA'}, 'Location', 'best');
    end
end
nexttile;
hold on;
for mi = 1:2
    plot(xIt, mean(convMean(:, mi, :), 3), 'LineWidth', 2, 'Color', cvColors(mi, :));
end
hold off;
grid on;
title('Average of all scenarios');
saveFigureSafe(fig10, fullfile(datasetRoot, 'Step7_Convergence.png'));

fig11 = figure('Name', 'Objective Comparison', 'Color', 'w', 'Position', [60 60 1100 550]);
JplotMat = [Jexh, JmeanMat];
bh = bar(JplotMat);
hold on;
for i = 2:size(JplotMat, 2)
    errorbar(bh(i).XEndPoints, JplotMat(:, i), JstdMat(:, i - 1), 'k.', 'HandleVisibility', 'off');
end
hold off;
grid on;
set(gca, 'XTickLabel', cellstr(scenarioLabels));
xlabel('Scenario');
ylabel('Final objective J (mean +/- std)');
title('Final objective value of each method');
legend([{'Reference (top-QUBO)'}, methodNames], 'Location', 'best');
saveFigureSafe(fig11, fullfile(datasetRoot, 'Step7_Objective_Comparison.png'));

fig12 = figure('Name', 'Step 6 Metrics', 'Color', 'w', 'Position', [80 80 1400 750]);
tl12 = tiledlayout(2, 3, 'TileSpacing', 'compact', 'Padding', 'compact');
title(tl12, 'Unoptimized (Step 4) vs Adaptive SPSA-QAOA');
metricNames = {'Active power loss (kW)', 'Voltage deviation (p.u.)', 'Minimum VSI (higher = better)', 'Renewable utilization (%)', 'Operating cost ($/h)', 'Renewable curtailment (%)'};
metricMat = {[lossU lossP], [vdU vdP], [vsiU vsiP], [reuU reuP], [costU costP], [curtU curtP]};
for q = 1:6
    nexttile;
    bar(metricMat{q});
    grid on;
    set(gca, 'XTickLabel', cellstr(scenarioLabels));
    title(metricNames{q});
    if q == 1
        legend({'Unoptimized (Step 4)', 'Adaptive SPSA-QAOA'}, 'Location', 'best');
    end
end
saveFigureSafe(fig12, fullfile(datasetRoot, 'Step6_Metrics.png'));

fig13 = figure('Name', 'Min Voltage Optimized', 'Color', 'w', 'Position', [100 100 1000 550]);
hold on;
for k = 1:numK
    plot(timeHours, Rbest{k}.series.vmin, '-', 'LineWidth', 1.8, 'Color', scColors(k, :));
end
for k = 1:numK
    plot(timeHours, Runopt{k}.series.vmin, '--', 'LineWidth', 1.2, 'Color', scColors(k, :), 'HandleVisibility', 'off');
end
yline(vLimits(1), 'r:', 'LineWidth', 1.2);
hold off;
grid on;
xlim([0 24]);
xlabel('Time of day (hours)');
ylabel('Minimum bus voltage (p.u.)');
title('Minimum voltage: proposed (solid) vs unoptimized (dashed)');
legend(cellstr(scenarioLabels), 'Location', 'best');
saveFigureSafe(fig13, fullfile(datasetRoot, 'Step6_Min_Voltage_Optimized.png'));

fig14 = figure('Name', 'Stability', 'Color', 'w', 'Position', [120 120 900 550]);
boxplot(reshape(JRuns(:, 4, :), nRuns, numK), 'Labels', cellstr(scenarioLabels));
grid on;
xlabel('Scenario');
ylabel('Final J of Adaptive SPSA-QAOA');
title(sprintf('Optimization stability over %d runs', nRuns));
saveFigureSafe(fig14, fullfile(datasetRoot, 'Step7_Stability.png'));

fig15 = figure('Name', 'Computation Time', 'Color', 'w', 'Position', [140 140 1000 550]);
bar([enumTime, timeMean]);
grid on;
set(gca, 'XTickLabel', cellstr(scenarioLabels));
xlabel('Scenario');
ylabel('Time (s)');
title('Computational time per method (classical simulation)');
legend([{'Exhaustive AC-PF'}, methodNames], 'Location', 'best');
saveFigureSafe(fig15, fullfile(datasetRoot, 'Step7_Computation_Time.png'));

%% ------------------------------------------------------------
% Save Excel and MAT
% ------------------------------------------------------------
spsaExcel = fullfile(datasetRoot, 'SPSA_QAOA_Results.xlsx');
if exist(spsaExcel, 'file') == 2
    delete(spsaExcel);
end
quboTable = table(scenarioLabels, qfitR2, qfitSpearman, quboMinMatchesTrue, enumTime, 'VariableNames', {'Scenario', 'QUBO_Fit_R2', 'QUBO_Spearman', 'QUBO_Min_Equals_True_Min', 'Enumeration_Time_s'});
valTable = table(scenarioLabels, chkVolt, chkBranch, chkBalance, chkGen, 'VariableNames', {'Scenario', 'Voltage_OK', 'Branch_OK', 'Balance_OK', 'Generator_OK'});
writetable(sol5, spsaExcel, 'Sheet', 'Step5_Solutions');
writetable(quboTable, spsaExcel, 'Sheet', 'Step5_QUBO');
writetable(valTable, spsaExcel, 'Sheet', 'Step5_ACPF_Validation');
writetable(res6, spsaExcel, 'Sheet', 'Step6_Results');
writetable(conv7, spsaExcel, 'Sheet', 'Step7_Convergence');
writetable(timeTable, spsaExcel, 'Sheet', 'Step7_Time');
writetable(jTable, spsaExcel, 'Sheet', 'Step7_Objective');
writetable(impTable, spsaExcel, 'Sheet', 'Step7_Improvement');
writetable(stab7, spsaExcel, 'Sheet', 'Step7_Stability');
save(fullfile(datasetRoot, 'SPSA_QAOA_Results.mat'), 'P', 'Qmat', 'c0', 'qfitR2', 'Jsample', 'Es', 'Jexh', 'bestState', 'bestRun', 'JRuns', 'JobjRuns', 'timeRuns', 'stateRuns', 'feasRuns', 'convHist', 'sol5', 'res6', 'conv7', 'timeTable', 'jTable', 'impTable', 'stab7', 'methodNames');
fprintf('\nSTEPS 1-7 COMPLETED. Results saved in: %s\n', datasetRoot);

%% ============================================================
% LOCAL FUNCTIONS
% ============================================================
function saveFigureSafe(figHandle, filePath)
    drawnow;
    try
        exportgraphics(figHandle, filePath, 'Resolution', 300);
    catch
        try
            saveas(figHandle, filePath);
        catch ME
            warning('Could not save figure %s: %s', filePath, ME.message);
        end
    end
end

function [vm, lossMW, slackMW, ok] = solveNetworkPF(netData, PdMW, QdMVAr)
    n = numel(PdMW);
    vm = nan(n, 1);
    lossMW = NaN;
    slackMW = NaN;
    ok = false;
    parent = zeros(n, 1);
    zBr = zeros(n, 1);
    parent(netData.to) = netData.from;
    zBr(netData.to) = netData.rPu + 1i * netData.xPu;
    S = (PdMW + 1i * QdMVAr) / netData.baseMVA;
    V = ones(n, 1);
    for iter = 1:200
        Iacc = conj(S ./ V);
        for b = n:-1:2
            Iacc(parent(b)) = Iacc(parent(b)) + Iacc(b);
        end
        Vnew = V;
        for b = 2:n
            Vnew(b) = Vnew(parent(b)) - zBr(b) * Iacc(b);
        end
        err = max(abs(Vnew - V));
        V = Vnew;
        if err < 1e-9
            ok = true;
            break;
        end
    end
    if ~ok
        return;
    end
    Iacc = conj(S ./ V);
    for b = n:-1:2
        Iacc(parent(b)) = Iacc(parent(b)) + Iacc(b);
    end
    lossPu = 0;
    for b = 2:n
        lossPu = lossPu + abs(Iacc(b))^2 * real(zBr(b));
    end
    vm = abs(V);
    lossMW = lossPu * netData.baseMVA;
    slackMW = real(V(1) * conj(Iacc(1))) * netData.baseMVA;
end

function [V, Iacc, ok] = radialPF(P, Pd, Qd)
    n = numel(Pd);
    parent = P.parent;
    zBr = P.zBr;
    S = (Pd + 1i * Qd) / P.baseMVA;
    V = ones(n, 1);
    Iacc = zeros(n, 1);
    ok = false;
    for iter = 1:100
        Iacc = conj(S ./ V);
        for b = n:-1:2
            Iacc(parent(b)) = Iacc(parent(b)) + Iacc(b);
        end
        Vnew = V;
        for b = 2:n
            Vnew(b) = Vnew(parent(b)) - zBr(b) * Iacc(b);
        end
        err = max(abs(Vnew - V));
        V = Vnew;
        if err < 1e-8
            ok = true;
            break;
        end
    end
    if ok
        Iacc = conj(S ./ V);
        for b = n:-1:2
            Iacc(parent(b)) = Iacc(parent(b)) + Iacc(b);
        end
    end
end

function v = minVSI(V, Iacc, P)
    vm = abs(V);
    Vi = vm(P.parent(2:end));
    Sr = V(2:end) .* conj(Iacc(2:end));
    Pj = real(Sr);
    Qj = imag(Sr);
    rr = P.rBr(2:end);
    xx = P.xBr(2:end);
    v = min(Vi.^4 - 4 * (Pj .* xx - Qj .* rr).^2 - 4 * (Pj .* rr + Qj .* xx) .* Vi.^2);
end

function dec = decodeBits(bits, P)
    dec.level = zeros(1, P.numGen);
    for g = 1:P.numGen
        b = bits((g - 1) * P.bpg + (1:P.bpg));
        v = sum(b .* 2.^(0:P.bpg-1));
        dec.level(g) = P.dispLevels(v + 1);
    end
    dec.batt = bits(P.battBit);
    dec.capSteps = sum(bits(P.capBits) .* 2.^(0:numel(P.capBits)-1));
    dec.capSteps2 = sum(bits(P.capBits2) .* 2.^(0:numel(P.capBits2)-1));
    dec.Qcap = dec.capSteps * P.capStepMVAr;
    dec.Qcap2 = dec.capSteps2 * P.capStepMVAr2;
end

function R = evalConfig(bits, k, tIdx, P)
    dec = decodeBits(bits, P);
    nt = numel(tIdx);
    lossS = zeros(nt, 1);
    slackS = zeros(nt, 1);
    vdS = zeros(nt, 1);
    vminS = zeros(nt, 1);
    vmaxS = zeros(nt, 1);
    vioV = zeros(nt, 1);
    vioB = zeros(nt, 1);
    vioBal = zeros(nt, 1);
    costS = zeros(nt, 1);
    vsiS = zeros(nt, 1);
    loadMaxS = zeros(nt, 1);
    usedS = zeros(nt, 1);
    availS = zeros(nt, 1);
    ok = true;
    for ti = 1:nt
        t = tIdx(ti);
        Pd = P.Pd0;
        Qd = P.Qd0;
        pUse = 0;
        pAvail = 0;
        for g = 1:P.numGen
            pa = P.genMW(t, g, k);
            pu = dec.level(g) * pa;
            Pd(P.busRow(g)) = Pd(P.busRow(g)) - pu;
            pUse = pUse + pu;
            pAvail = pAvail + pa;
        end
        pb = dec.batt * P.battSched(t, k) * P.battRatedMW;
        Pd(P.battRow) = Pd(P.battRow) - pb;
        Qd(P.capRow) = Qd(P.capRow) - dec.Qcap;
        Qd(P.capRow2) = Qd(P.capRow2) - dec.Qcap2;
        [V, Iacc, okPF] = radialPF(P, Pd, Qd);
        if ~okPF
            ok = false;
            break;
        end
        vm = abs(V);
        slack = real(V(1) * conj(Iacc(1))) * P.baseMVA;
        lossS(ti) = sum(abs(Iacc(2:end)).^2 .* real(P.zBr(2:end))) * P.baseMVA;
        slackS(ti) = slack;
        vdS(ti) = sum(abs(vm - 1));
        vminS(ti) = min(vm);
        vmaxS(ti) = max(vm);
        vioV(ti) = sum(max(0, P.vLo - vm).^2 + max(0, vm - P.vHi).^2);
        loading = abs(Iacc(2:end)) ./ P.ratingPu(2:end);
        loadMaxS(ti) = max(loading);
        vioB(ti) = sum(max(0, loading - 1).^2);
        vioBal(ti) = max(0, -slack)^2;
        costS(ti) = P.cGrid * max(slack, 0) + P.cRen * pUse + P.cBatt * abs(pb) + P.cCap * (dec.capSteps + dec.capSteps2);
        vsiS(ti) = minVSI(V, Iacc, P);
        usedS(ti) = pUse;
        availS(ti) = pAvail;
    end
    if ~ok
        R = struct('ok', false, 'J', 1e3, 'Jobj', 1e3, 'feasible', false, 'dec', dec, 'lossMW', NaN, 'dailyLossMWh', NaN, 'VD', NaN, 'VSImin', NaN, 'REU', NaN, 'curt', NaN, 'cost', NaN, 'Vmin', NaN, 'Vmax', NaN, 'nViolV', NaN, 'maxLoading', NaN, 'minSlack', NaN, 'series', []);
        return;
    end
    R.ok = true;
    R.dec = dec;
    R.lossMW = mean(lossS);
    R.dailyLossMWh = sum(lossS) * P.dtHours;
    R.VD = mean(vdS);
    R.VSImin = min(vsiS);
    R.REU = 100 * sum(usedS) / max(sum(availS), eps);
    R.curt = 1 - R.REU / 100;
    R.cost = mean(costS);
    R.Vmin = min(vminS);
    R.Vmax = max(vmaxS);
    R.nViolV = sum(vminS < P.vLo - P.vTol | vmaxS > P.vHi + P.vTol);
    R.maxLoading = max(loadMaxS);
    R.minSlack = min(slackS);
    R.Jobj = P.w(1) * R.lossMW / P.refLoss + P.w(2) * R.VD / P.refVD + P.w(3) * R.cost / P.refCost + P.w(4) * R.curt;
    R.J = R.Jobj + P.lam(1) * mean(vioV) + P.lam(2) * mean(vioB) + P.lam(3) * mean(vioBal);
    R.feasible = (R.nViolV == 0) && (R.maxLoading <= 1 + 1e-9) && (R.minSlack >= -1e-9);
    R.series = struct('loss', lossS, 'slack', slackS, 'vmin', vminS, 'vmax', vmaxS, 'vd', vdS, 'cost', costS);
end

function [sBest, valCol] = validateAndSelect(cands, valCol, Xall, k, P)
    cands = unique(cands(:)', 'stable');
    nC = numel(cands);
    Jc = zeros(1, nC);
    fe = false(1, nC);
    for i = 1:nC
        s = cands(i);
        if isempty(valCol{s})
            valCol{s} = evalConfig(Xall(s, :), k, 1:P.numT, P);
        end
        Jc(i) = valCol{s}.J;
        fe(i) = valCol{s}.feasible;
    end
    if any(fe)
        pool = find(fe);
    else
        pool = 1:nC;
    end
    [~, mi] = min(Jc(pool));
    sBest = cands(pool(mi));
end

function p = qaoaProb(theta, Esk, n, depth)
    dim = numel(Esk);
    psi = ones(dim, 1) / sqrt(dim);
    for l = 1:depth
        psi = psi .* exp(-1i * theta(l) * Esk(:));
        psi = applyMixer(psi, theta(depth + l), n);
    end
    p = abs(psi).^2;
    p = p / sum(p);
end

function psi = applyMixer(psi, beta, n)
    c = cos(beta);
    s = sin(beta);
    dim = numel(psi);
    for q = 1:n
        M = reshape(psi, 2^(q-1), 2, dim / 2^q);
        a = M(:, 1, :);
        b = M(:, 2, :);
        M(:, 1, :) = c * a - 1i * s * b;
        M(:, 2, :) = c * b - 1i * s * a;
        psi = reshape(M, dim, 1);
    end
end

function f = qaoaExpect(theta, Esk, n, depth)
    p = qaoaProb(theta, Esk, n, depth);
    f = p' * Esk(:);
end

function [f, se] = qaoaSample(theta, Esk, n, depth, shots)
    p = qaoaProb(theta, Esk, n, depth);
    idx = randsample(numel(Esk), shots, true, p);
    vals = Esk(idx);
    f = mean(vals);
    se = std(vals) / sqrt(shots);
end

function cands = measureCandidates(theta, Esk, n, depth, shots, numCand)
    p = qaoaProb(theta, Esk, n, depth);
    idx = randsample(numel(Esk), shots, true, p);
    u = unique(idx);
    [~, o] = sort(Esk(u));
    cands = u(o(1:min(numCand, numel(u))));
end

function out = runSPSA(Esk, n, depth, theta0, iters, shots, cfg)
    th = theta0(:);
    np = numel(th);
    hist = zeros(iters + 1, 1);
    hist(1) = qaoaExpect(th, Esk, n, depth);
    a = cfg.a;
    scale = 1;
    [fCur, sCur] = qaoaSample(th, Esk, n, depth, shots);
    if cfg.adaptive
        gMag = 0;
        for r = 1:5
            d = 2 * (rand(np, 1) > 0.5) - 1;
            fp = qaoaSample(th + cfg.c * d, Esk, n, depth, shots);
            fm = qaoaSample(th - cfg.c * d, Esk, n, depth, shots);
            gMag = gMag + abs(fp - fm) / (2 * cfg.c);
        end
        gMag = gMag / 5;
        a = cfg.stepTarget * (cfg.A + 1)^cfg.alpha / max(gMag, 1e-6);
    end
    for k = 0:iters-1
        ak = a * scale / (cfg.A + k + 1)^cfg.alpha;
        ck = cfg.c / (k + 1)^cfg.gamma;
        d = 2 * (rand(np, 1) > 0.5) - 1;
        fp = qaoaSample(th + ck * d, Esk, n, depth, shots);
        fm = qaoaSample(th - ck * d, Esk, n, depth, shots);
        g = (fp - fm) / (2 * ck) * d;
        step = max(min(ak * g, cfg.maxStep), -cfg.maxStep);
        thNew = th - step;
        thNew(1:depth) = mod(thNew(1:depth), 2 * pi);
        thNew(depth+1:end) = mod(thNew(depth+1:end), pi);
        if cfg.adaptive
            [fNew, sNew] = qaoaSample(thNew, Esk, n, depth, shots);
            if fNew > fCur + 2 * sqrt(sNew^2 + sCur^2)
                scale = max(scale * 0.5, 0.05);
            else
                th = thNew;
                fCur = fNew;
                sCur = sNew;
                scale = min(scale * 1.1, 2);
            end
        else
            th = thNew;
        end
        hist(k + 2) = qaoaExpect(th, Esk, n, depth);
    end
    out.theta = th;
    out.hist = hist;
end

function visited = runSA(Esk, n, steps, T0, Tend)
    s = randi(numel(Esk));
    cur = Esk(s);
    visited = zeros(steps + 1, 1);
    visited(1) = s;
    for it = 1:steps
        T = T0 * (Tend / T0)^((it - 1) / (steps - 1));
        q = randi(n);
        sNew = bitxor(s - 1, 2^(q - 1)) + 1;
        d = Esk(sNew) - cur;
        if d <= 0 || rand < exp(-d / T)
            s = sNew;
            cur = Esk(sNew);
        end
        visited(it + 1) = s;
    end
end