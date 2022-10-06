require "rubygems"
require "octokit"
require "json"
require "logger"
require "safe_yaml"

CLIENT = Octokit::Client.new(:access_token => ENV["GITHUB_TOKEN"])
REPOSITORY= ENV["INDIA_REPO_NWO"]
BASE_PATH = "website/data/open-source"
@logger = Logger.new(STDOUT)

# Flag for checking if the issues are present
$ISSUES_PRESENT = false
# Array to store maintainers with failed validations in {BASE_PATH}/maintainers.yml file
MAINTAINERS_FAILED_VALIDATION = []
# Array to store projects with failed validation in {BASE_PATH}/projects.yml file
OSSPROJECTS_FAILED_VALIDATION = []
# Array to store projects with failed validation in {BASE_PATH}/social-good-projects.yml file
SOCIALGOOD_FAILED_VALIDATION = []

# Function to sleep the script for sometime when the API limit is hit
def waitTillLimitReset
    timeTillReset = CLIENT.rate_limit.resets_in + 5
    @logger.info("API limit reached while fetching... Sleeping for #{timeTillReset} seconds 😴 brb")
    sleep(timeTillReset)
end

# Function to prepare the job summary to be added to the PR if it has any issues
# Params:
# category: Category of the issue (maintainers/ossProjects/socialGoodProjects)
# issues: Array of issues present for the PR
# title: Name of the project/maintainer
def prepareJobSummary(category, issues, title)
    $ISSUES_PRESENT = true
    body = {
        :title => title,
        :issues => issues
    }
    if category == "maintainers"
        MAINTAINERS_FAILED_VALIDATION.push(body)
    elsif category == "ossProjects"
        OSSPROJECTS_FAILED_VALIDATION.push(body)
    else
        SOCIALGOOD_FAILED_VALIDATION.push(body)
    end
end

# Function to create job summary
def createJobSummary
    comment = "PR cannot be merged due to following issues:\n"
    if MAINTAINERS_FAILED_VALIDATION.length() != 0
        comment += "- Maintainers\n"
        for issueObject in MAINTAINERS_FAILED_VALIDATION do
            comment += "\t- `#{issueObject[:title]}`\n"
            for issue in issueObject[:issues] do
                comment += "\t\t- #{issue}\n"
            end
        end
    end
    if OSSPROJECTS_FAILED_VALIDATION.length() != 0
        comment += "- OSS Projects\n"
        for issueObject in OSSPROJECTS_FAILED_VALIDATION do
            comment += "\t- `#{issueObject[:title]}`\n"
            for issue in issueObject[:issues] do
                comment += "\t\t- #{issue}\n"
            end
        end
    end
    if SOCIALGOOD_FAILED_VALIDATION.length() != 0
        comment += "- Social Good Projects\n"
        for issueObject in SOCIALGOOD_FAILED_VALIDATION do
            comment += "\t- `#{issueObject[:title]}`\n"
            for issue in issueObject[:issues] do
                comment += "\t\t- #{issue}\n"
            end
        end
    end
    @logger.info("Summary: #{comment}")
    File.write(ENV["GITHUB_STEP_SUMMARY"], comment)
end

# Function for fetching the details of a maintainer
# Params:
# maintainer: Name of the maintainer whos details need be fetched
# Returns:
# maintainer object
def getMaintainer(maintainer)
    data = CLIENT.user(maintainer)
    return data
end

# Function for validating if the maintainer is valid
# Returns: Array of failed checks
def validateMaintainer(data)
    fails = []
    # Check if the user has atleast 1 follower
    if data.followers < 1
        fails.push("Maintainer has less than 1 follower")
    end
    return fails
end

# Function for fetching the details of a project
# Params:
# projectName: Name of the project whos details need be fetched
# Returns:
# project object
def getProject(projectName)
    data = CLIENT.repository(projectName)
    return data
end

# Function for validating if the project is valid
# Returns: Array of failed checks
def validateProject(data, isSocialGood = false)
    fails = []
    # Check if project is private
    if data.private
        fails.push("Project is either private or doesn't exist!")
    end 
    # Check if project has license
    if data.license == nil
        fails.push("Project doesn't have a license")
    end
    # Check if project has atleast 100 stars
    if data.stargazers_count < 100 && !isSocialGood
        fails.push("Project has less than 100 stars")
    end
    return fails
end

# Function for fetching all the details of the maintainers 
# from the maintainers list at {BASE_PATH}/maintainers.yml
# and check if the maintainers are valid or not
def checkMaintainersData()
    maintainersList = JSON.parse(YAML.load(File.open("#{BASE_PATH}/maintainers.yml"), :safe => true).to_json)
    for city in maintainersList.keys do
        for maintainerName in maintainersList[city] do
            begin
                maintainer = getMaintainer(maintainerName)
                issues = validateMaintainer(maintainer)
                if issues.length() != 0
                    preparePRComments("maintainers", issues, maintainerName)
                end
            rescue => e
                @logger.info("Error #{e.response_status}")
                if e.response_status == 403
                    waitTillLimitReset()
                    maintainer = getMaintainer(maintainerName)
                    issues = validateMaintainer(maintainer)
                    if issues.length() != 0
                        preparePRComments("maintainers", issues, maintainerName)
                    end
                else
                    @logger.info("Error on maintainer: #{maintainerName}")
                    preparePRComments("maintainers", ["User with username #{maintainerName} doesn't exist!"], maintainerName)
                end
            end
        end
    end
end

# Function for fetching all the details of the oss projects and social good projects
# from the projects list at {BASE_PATH}/{fileName}
# and check if the projects are valid or not
# Params:
# fileName: 
#   - Indicates the file location of the list of projects present
#   - Values can be either "projects.yml" or "social-good-projects.yml" 
def checkProjectsData(fileName)
    projectsList = JSON.parse(YAML.load(File.open("#{BASE_PATH}/#{fileName}"), :safe => true).to_json)
    if fileName == "projects.yml"
        issueCategory = "ossProjects"
    else
        issueCategory = "socialGoodProjects"
    end
    for category in projectsList.keys do
        if projectsList[category] == nil then
            preparePRComments(issueCategory, ["Each category should contain atleast 1 project."], "#{category} in #{fileName}")
            next
        end
        for projectName in projectsList[category] do
            begin
                project = getProject(projectName)
                issues = validateProject(project, issueCategory == "socialGoodProjects")
                if issues.length() != 0
                    preparePRComments(issueCategory, issues, projectName)
                end
            rescue => e
                @logger.info("Error: #{e.response_status}")
                if e.response_status == 403
                    waitTillLimitReset()
                    project = getProject(projectName)
                    issues = validateProject(project, issueCategory == "socialGoodProjects")
                    if issues.length() != 0
                        preparePRComments(issueCategory, issues, projectName)
                    end
                else
                    @logger.info("Error on project: #{projectName}")
                    preparePRComments(issueCategory, ["Project #{projectName} is either private or doesn't exist!"], projectName)
                end
            end
        end
    end
end

@logger.info("-------------------------------")
@logger.info("Checking Maintainers...")
checkMaintainersData()
@logger.info("Maintainers data checked")
@logger.info("-------------------------------")
@logger.info("Checking OSS Projects...")
checkProjectsData("projects.yml")
@logger.info("OSS Projects data checked")
@logger.info("-------------------------------")
@logger.info("Checking Social Good Projects...")
checkProjectsData("social-good-projects.yml")
@logger.info("Social Good Projects data checked")
@logger.info("-------------------------------")

if MAINTAINERS_FAILED_VALIDATION.length() != 0 || OSSPROJECTS_FAILED_VALIDATION.length() != 0 || SOCIALGOOD_FAILED_VALIDATION.length() != 0
    @logger.info("Creating Comment")
    createPRSummary()
    exit(1)
end
@logger.info("-------------------------------")
