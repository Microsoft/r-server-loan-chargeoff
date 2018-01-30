<#
.SYNOPSIS
Script to provide Loan ChargeOff predictions, using SQL Server R Services using MicrosoftML and RevoScaleR packages.

.DESCRIPTION
This script will show the E2E work flow of loan chargeoff prediction machine learning
templates with Microsoft SQL Server 2016 and SQL Servevr R Services.

.PARAMETER ServerName
SQL Server instance

.PARAMETER DBName
Name of the database

.PARAMETER sqlUsername
Database user name

.PARAMETER sqlPassword
Database password

.PARAMETER uninterrupted
Whether to run the whole workflow uninterrupted or in interactive mode (y/n)

.PARAMETER dataPath
Folder path with raw csv data files to import into SQL Server database

.PARAMETER datasize
size of the dataset to use (10k, 100k, 1m)

.EXAMPLE
.\Loan_ChargeOff.ps1 -ServerName $env:COMPUTERNAME -DBName LoanChargeOff -sqlUsername sqluser -sqlPassword "MyP#assword1" -uninterrupted y -dataPath ..\..\Data -dataSize "100k"
#>
[CmdletBinding()]
param(
# SQL server address
[parameter(Mandatory=$true,ParameterSetName = "LCR")]
[ValidateNotNullOrEmpty()] 
[String]    
$ServerName = "",

# SQL server database name
[parameter(Mandatory=$true,ParameterSetName = "LCR")]
[ValidateNotNullOrEmpty()]
[String]
$DBName = "",

[parameter(Mandatory=$true,ParameterSetName = "LCR")]
[ValidateNotNullOrEmpty()]
[String]
$sqlUsername ="",

[parameter(Mandatory=$true,ParameterSetName = "LCR")]
[ValidateNotNullOrEmpty()]
[String]
$sqlPassword ="",

[parameter(Mandatory=$false,ParameterSetName = "LCR")]
[ValidateNotNullOrEmpty()]
[ValidateSet("y", "n", "yes", "no", IgnoreCase = $true)]
[String]
$uninterrupted="y",

[parameter(Mandatory=$true,ParameterSetName = "LCR")]
[ValidateNotNullOrEmpty()]
[String]
$dataPath = "",

[parameter(Mandatory=$false,ParameterSetName = "LCR")]
[ValidateSet("10k", "100k", "1m")]
[String]
$dataSize = "10k"
)

$scriptPath = Get-Location
$filePath = $scriptPath.Path+ "\"
$dataFilePath = $dataPath + "\"

##########################################################################
# Script level variables
##########################################################################
$yesArray = "y", "yes"
$noArray = "n", "no"
$table_suffix = "_" + $dataSize

$trainingTable = "loan_chargeoff_train" + $table_suffix
$testTable = "loan_chargeoff_test" + $table_suffix
$evalScoreTable = "loan_chargeoff_eval_score" + $table_suffix
$scoreTable = "loan_chargeoff_score" + $table_suffix
$modelTable = "loan_chargeoff_models" + $table_suffix
$predictionTable = "loan_chargeoff_prediction" + $table_suffix
$selectedFeaturesTable = "selected_features" + $table_suffix
$modelNames = @{"logistic_reg" = "Logistic Regression model with rxLogisticRegression";"fast_linear" = "Linear binary classification model with rxFastLinear";"fast_trees" = "Fast Decision Trees model with rxFastTrees";"fast_forest" = "Random Forest with rxFastForest";"neural_net" = "Neural Network with rxNeuralNet"}

##########################################################################
# Function wrapper to invoke SQL command
##########################################################################
function ExecuteSQL
{
param(
[String]
$sqlscript,
[String]
$VariableArray=""
)
    Invoke-Sqlcmd -ServerInstance $ServerName  -Database $DBName -Username $sqlUsername -Password "$sqlPassword" -InputFile $sqlscript -Variable $VariableArray -QueryTimeout 200000
}
##########################################################################
# Function wrapper to invoke SQL query
##########################################################################
function ExecuteSQLQuery
{
param(
[String]
$sqlquery
)
    Invoke-Sqlcmd -ServerInstance $ServerName  -Database $DBName -Username $sqlUsername -Password "$sqlPassword" -Query $sqlquery -QueryTimeout 200000
}

##########################################################################
# Construct the SQL connection strings
##########################################################################
$connectionString = "Driver=SQL Server;Server=$ServerName;Database=$DBName;UID=$sqlUsername;PWD=$sqlPassword"
$ServerName2="localhost"
$connectionString2 = "Driver=SQL Server;Server=$ServerName2;Database=$DBName;UID=$sqlUsername;PWD=$sqlPassword"

##########################################################################
# Check if the SQL server or database exists
##########################################################################
$query = "SELECT database_id FROM sys.databases WHERE NAME = '$DBName'"
$DB_ID = Invoke-Sqlcmd -ServerInstance $ServerName -Username $sqlUsername -Password "$sqlPassword" -Query $query -ErrorAction SilentlyContinue
if (!$db_id)
{
    Write-Host -ForegroundColor Red "Failed the test to connect to SQL server: $ServerName database: $DBName !"
    Write-Host -ForegroundColor Red "Please make sure: `n`t 1. SQL Server: $ServerName exists;
                                     `n`t 2. SQL database: $DBName exists;
                                     `n`t 3. SQL user: $sqlUsername has the right credential for SQL server access."
    exit
}

$query = "USE $DBName;"
Invoke-Sqlcmd -ServerInstance $ServerName -Username $sqlUsername -Password "$sqlPassword" -Query $query 

##########################################################################
# Common functions
##########################################################################
function CreateTablesAndLoadData
{
    # create training and test tables
    Write-Host -ForeGroundColor 'green' ("Create SQL tables: member_info, loan_info, payments_info")
    $script = $filePath + "step1_create_tables.sql"
    ExecuteSQL $script "datasize = $dataSize"

    Write-Host -ForeGroundColor 'green' ("Populate SQL tables: member_info, loan_info, payments_info")
    $dataList = "member_info", "loan_info", "payments_info"

    # upload csv files into SQL tables
    foreach ($dataFile in $dataList)
    {
        $destination = $dataFilePath + $dataFile + $table_suffix + ".csv"
        $error_file = $dataFilePath + $dataFile + $table_suffix + ".error"
        Write-Host -ForeGroundColor 'magenta'("    Populate SQL table: {0}... from {1}" -f $dataFile, $destination)
        $tableName = $DBName + ".dbo." + $dataFile + $table_suffix
        $tableSchema = $dataFilePath + $dataFile + $table_suffix + ".xml"
        bcp $tableName format nul -c -x -f $tableSchema  -U $sqlUsername -S $ServerName -P "{$sqlPassword}"  -t '|'
        Write-Host -ForeGroundColor 'magenta'("    Loading {0} to SQL table..." -f $dataFile)
        $bcpStart = Get-Date
        bcp $tableName in $destination -t '|' -S $ServerName -f $tableSchema -F 2 -C "RAW" -b 100000 -U $sqlUsername -P "{$sqlPassword}" -e $error_file
        if (!$?)
        {
            Write-Host -ForegroundColor Red "Error in BCP. Check any SQL error messages."
            throw
        }
        $bcpEnd = Get-Date
        $bcpTotal = ($bcpEnd - $bcpStart).ToString()
        Write-Host -ForeGroundColor 'magenta'("    Done...Loading {0} to SQL table {1} Total time: {2}" -f $dataFile, $tableName, $bcpTotal)
    }
}

function CreateViewsAndPersist
{
    # create the views for features and label with training, test and scoring split
    Write-Host -ForeGroundColor 'magenta'("    Creating features label view and persisting...")
    $script = $filepath + "step2_features_label_view.sql"
    $persistStart = Get-Date
    ExecuteSQL $script "datasize=$dataSize"
    $persistEnd = Get-Date
    $persistTime = ($persistEnd - $persistStart).ToString()
    Write-Host -ForeGroundColor 'magenta'("    Done creating features label view and persisting. Total time: {0}" -f $persistTime)
}

function TrainEvalModels
{
    # create the stored procedure for training
    $script = $filepath + "step3_train_test_model.sql"
    ExecuteSQL $script "datasize=$dataSize"
    Write-Host -ForeGroundColor 'magenta'("    Done creating training and eval stored proc...")

    # execute the training
    Write-Host -ForeGroundColor 'magenta'("    Starting training and evaluation of models...")
    foreach ($modelName in $modelNames.GetEnumerator())
    {
        Write-Host -ForeGroundColor 'Cyan' (" Training $($modelName.Value)...")
        $query = "EXEC train_model $trainingTable, $testTable, $evalScoreTable, $modelTable, $($modelName.Name), '$connectionString2'"
        $startModelling = Get-Date
        ExecuteSQLQuery $query
        $endModelling = Get-Date
        $totalModellingTime = ($endModelling-$startModelling).ToString()
        Write-Host -ForeGroundColor 'Cyan' (" Finished Training $($modelName.Value) Total time: {0}..." -f $totalModellingTime)
    }

    Write-Host -ForeGroundColor 'Cyan' (" Done with training and evaluation of models. Evaluation stats stored in $modelTable...")
}

function ScoreData
{
    # create the stored procedure for recommendations
    $script = $filepath + "step4_chargeoff_batch_prediction.sql"
    ExecuteSQL $script "datasize=$dataSize"
    Write-Host -ForeGroundColor 'magenta'("    Done creating batch scoring stored proc...")

    #score on the data
    $best_model = ExecuteSQLQuery "select top 1 model_name from $modelTable where f1score in (select max(f1score) from $modelTable)"
    Write-Host -ForeGroundColor 'Cyan' ("Scoring based on best performing model '$($modelNames.Get_Item($best_model.model_name))' score table = $scoreTable, prediction table = $predictionTable...")
    $scoring_query = "EXEC predict_chargeoff $scoreTable, $predictionTable, $modelTable"
    $scoringStart = Get-Date
    ExecuteSQLQuery $scoring_query
    $scoringEnd = Get-Date
    $scoringTotal = ($scoringEnd - $scoringStart).ToString()
    Write-Host -ForeGroundColor 'Cyan' ("Done batch scoring. Total time: {0}" -f $scoringTotal)
}

function OnDemandPrediction
{
    # create the stored procedure for recommendations
    $script = $filepath + "step4a_chargeoff_ondemand_prediction.sql"
    ExecuteSQL $script "datasize=$dataSize"
    Write-Host -ForeGroundColor 'magenta'("    Done creating on demand scoring stored proc [predict_chargeoff_ondemand]...")
}

function FeatureSelection
{
    # create the stored procedure for feature engineering
    $script = $filepath + "step2a_optional_feature_selection.sql"
    ExecuteSQL $script "datasize=$dataSize"

    # execute the feature engineering
    Write-Host -ForeGroundColor 'Cyan' (" selecting features using MicrosoftML selectFeatures mlTransform with Logistic Regression...")
    $query = "EXEC select_features $trainingTable, $testTable, $selectedFeaturesTable, '$connectionString2'"
    ExecuteSQLQuery $query
}
##########################################################################
# Running without interruption
##########################################################################
$startTime= Get-Date
Write-Host "Start time is:" $startTime

if ($uninterrupted -iIn $yesArray)
{
   try
   {
        # step 1. create tables and load data
        CreateTablesAndLoadData

        # step 2. create the views for features and label with training, test and scoring split
        CreateViewsAndPersist

        # step 3. Train and evaluate models
        TrainEvalModels
        
        # step 4. Data scoring
        ScoreData

        # step 4a. Create on demand prediction stored proc
        OnDemandPrediction

    }
    catch
    {
        Write-Host -ForegroundColor Yellow "Exception executing Data Science pipeline..."
        Write-Host -ForegroundColor Red $Error[0].Exception 
        throw
    }

    Write-Host -foregroundcolor 'green'("Loan ChargeOff Workflow Finished Successfully!")
}

if ($uninterrupted -iIn $noArray)
{

##########################################################################
# Create input tables and populate with data from csv files.
##########################################################################
Write-Host -foregroundcolor 'green' ("Step 1: Create and populate tables in Database" -f $dbname)
$ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'
if ($ans -eq 'E' -or $ans -eq 'e')
{
    return
} 
if ($ans -eq 'y' -or $ans -eq 'Y')
{
    try
    {
        CreateTablesAndLoadData
    }
    catch
    {
        Write-Host -ForegroundColor DarkYellow "Exception in populating database tables:"
        Write-Host -ForegroundColor Red $Error[0].Exception 
        throw
    }
}

##########################################################################
# Create and execute the scripts for data processing
##########################################################################
Write-Host -foregroundcolor 'green' ("Step 2: Data Processing/Create feature and label views and tables")
$ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'
if ($ans -eq 'E' -or $ans -eq 'e')
{
    return
} 
if ($ans -eq 'y' -or $ans -eq 'Y')
{
    CreateViewsAndPersist
}

##########################################################################
# Create and execute the stored procedure for feature selection (optional)
##########################################################################
Write-Host -foregroundcolor 'green' ("Step 2a: Feature Engineering (for demo purpose only, training step does it's own feature selection)")
$ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'
if ($ans -eq 'E' -or $ans -eq 'e')
{
    return
} 
if ($ans -eq 'y' -or $ans -eq 'Y')
{
    FeatureSelection
}

##########################################################################
# Create and execute the stored procedure for Training and evaluation
##########################################################################

Write-Host -foregroundcolor 'green' ("Step 3: Models Training and Evaluation")
$ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'
if ($ans -eq 'E' -or $ans -eq 'e')
{
    return
} 
if ($ans -eq 'y' -or $ans -eq 'Y')
{
    TrainEvalModels
}

##########################################################################
# Create and execute the stored procedure for charge_off predictions
##########################################################################

Write-Host -foregroundcolor 'green' ("Step 4: ChargeOff predictions")
$ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'
if ($ans -eq 'E' -or $ans -eq 'e')
{
    return
} 
if ($ans -eq 'y' -or $ans -eq 'Y')
{
    ScoreData
}

Write-Host -foregroundcolor 'green' ("Step 4a: Create on demand ChargeOff prediction stored proc")
$ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'
if ($ans -eq 'E' -or $ans -eq 'e')
{
    return
} 
if ($ans -eq 'y' -or $ans -eq 'Y')
{
    OnDemandPrediction
}


Write-Host -foregroundcolor 'green'("Loan Chargeoff Prediction Workflow Finished Successfully!")
}

$endTime =Get-Date
$totalTime = ($endTime-$startTime).ToString()
Write-Host "Finished running Loan_ChargeOff.ps1 at:" $endTime
Write-Host "Total time used: " -foregroundcolor 'green' $totalTime.ToString()