local url="https://www.equateplus.com"
--local url="http://localhost/test"

local baseurl=""
local reportOnce
local Version="1.13"
local CSRF_TOKEN=nil
local csrfpId=nil
local connection
local debugging=false

function connectWithCSRF(method, url, postContent, postContentType, headers)
  url=baseurl..url
  -- print("baseurl="..baseurl)
  postContentType=postContentType or "application/json"
  local content

  if headers == nil then
    headers={["X-Requested-With"]="XMLHttpRequest" }
  end

  if CSRF_TOKEN ~= nil then
    headers['CSRF_TOKEN']=CSRF_TOKEN
  else
    print("without CSRF_TOKEN")
  end
  if method == 'POST' then
    -- lprint(postContent)
    if csrfpId ~= nil then
      postContent=postContent.."&csrfpId="..csrfpId
    end
  end

  content, charset, mimeType, filename, headers = connection:request(method, url, postContent, postContentType, headers)
  csrfpIdTemp=string.match(content,"\"csrfpId\" *, *\"([^\"]+)\"")
  if csrfpIdTemp ~= '' then
    csrfpId=csrfpIdTemp
  end
  if debugging then
    -- tprint(headers)
    -- lprint(content)
  else
    --print "no debug"
  end
  if headers["CSRF_TOKEN"] then
    CSRF_TOKEN=headers["CSRF_TOKEN"]
    -- print("new CSRF_TOKEN="..CSRF_TOKEN)
    -- if debugging then print("new CSRF_TOKEN") end
  end
  return content
end

WebBanking{version=Version, url=url,services    = {"EquatePlus"},
  description = "Depot von EquatePlus"}


function SupportsBank (protocol, bankCode)
  return  protocol == ProtocolWebBanking and bankCode == "EquatePlus"  -- .
end

function lprint(text)
  repeat
    print("  ",string.sub(text,1,60))
    text=string.sub(text,61)
  until text == ''
end

function tprint (tbl, indent)
  if not indent then indent = 3 end
  for k, v in pairs(tbl) do
    formatting = string.rep(" ", indent) .. k .. ": "
    --if debugging and (type(v) == 'string') then
    --  print(formatting .. type(v).."'"..v.."'")
    --else
      print(formatting .. type(v))
    --end
    if type(v) == 'table' and indent < 9 then tprint(v,indent+3) end
  end
end

function InitializeSession (protocol, bankCode, username, username2, password, username3)


  -- Login.
  baseurl=""
  debugging=false
  CSRF_TOKEN=nil
  csrfpId=nil
  connection = Connection()
  if string.sub(username,1,1) == '#' then
    print("Debugging, remove # char from username.")
    username=string.sub(username,2)
    debugging=true
  end
  print("username="..username)
  -- get login page
  html = HTML(connectWithCSRF("GET",url))
  -- tprint(html)
  -- first login stage
  print("login first stage")
  html:xpath("//*[@id='eqUserId']"):attr("value", username)
  html:xpath("//*[@id='submitField']"):attr("value","Continue Login")
  html= HTML(connectWithCSRF(html:xpath("//*[@id='loginForm']"):submit()))
  -- tprint(html)
  -- second login stage
  print("login second stage")
  html:xpath("//*[@id='eqUserId']"):attr("value", username)
  html:xpath("//*[@id='eqPwdId']"):attr("value", password)
  html:xpath("//*[@id='submitField']"):attr("value","Continue")
  if html:xpath("//*[@id='loginForm']"):text() == '' then return "EquatePlus plugin error: No login mask found!" end
  content, charset, mimeType, filename, headers = connectWithCSRF(html:xpath("//*[@id='loginForm']"):submit())
  html= HTML(content)

  -- base url
  baseurl=connection:getBaseURL():match('^(.*/)')
  print("baseurl="..baseurl)

  if CSRF_TOKEN ~= nil  then
    return nil
  end

  return LoginFailed
end



function ListAccounts (knownAccounts)
  local user=JSON(connectWithCSRF("GET","services/user/get")):dictionary()

  if debugging then tprint (user) end
  -- Return array of accounts.
  reportOnce=true
  local account
  local status,err = pcall( function()
    account = {
      name = "Equateplus "..user["companyId"],
      --owner = user["participant"]["firstName"]["displayValue"].." "..user["participant"]["lastName"]["displayValue"],
      accountNumber = user["participant"]["userId"],
      bankCode = "equatePlus",
      currency = user["reportingCurrency"]["code"],
      portfolio = true,
      type = AccountTypePortfolio
    }
  end)--pcall
  bugReport(status,err,user)
  return {account}
end

function RefreshAccount (account, since)
  local summary=JSON(connectWithCSRF("GET","services/planSummary/get")):dictionary()
  if debugging then tprint (summary) end
  local securities = {}
  reportOnce=true
  local status,err = pcall( function()
    for k,v in pairs(summary["entries"]) do
      local details=JSON(connectWithCSRF("POST","services/planDetails/get","{\"$type\":\"EntityIdentifier\",\"id\":\""..v["id"].."\"}")):dictionary()
      if debugging then tprint (details) end
      local status,err = pcall( function()
        for k,v in pairs(details["entries"]) do
          local status,err = pcall( function()
            for k,v in pairs(v["entries"]) do
              local status,err = pcall( function()
                local marketName=v["marketName"]
                local marketPrice=v["marketPrice"]["amount"]
                for k,v in pairs(v["entries"]) do
                  local status,err = pcall( function()
                    if(v["COST_BASIS"])then
                      -- "date": "2016-02-12T00:00:00.000",
                      local year,month,day=v["ALLOC_DATE"]["date"]:match ( "^(%d%d%d%d)%-(%d%d)%-(%d%d)")
                      --print (year.."-"..month.."-"..day)
                      if(year)then
                        tradeTimestamp=os.time({year=year,month=month,day=day})
                      end
                      local qty=0
                      if v["AVAIL_QTY"] and v["AVAIL_QTY"]["amount"] then
                        qty=v["AVAIL_QTY"]["amount"]
                      end

                      if v["LOCKED_QTY"] and v["LOCKED_QTY"]["amount"] then
                        qty=qty+v["LOCKED_QTY"]["amount"]
                      end

                      local security={
                        -- String name: Bezeichnung des Wertpapiers
                        name=v["VEHICLE_DESCRIPTION"],

                        -- String isin: ISIN
                        -- String securityNumber: WKN
                        -- String market: Börse
                        market=marketName,

                        -- String currency: Währung bei Nominalbetrag oder nil bei Stückzahl
                        -- Number quantity: Nominalbetrag oder Stückzahl
                        quantity=qty,

                        -- Number amount: Wert der Depotposition in Kontowährung
                        -- Number originalCurrencyAmount: Wert der Depotposition in Originalwährung
                        -- Number exchangeRate: Wechselkurs

                        -- Number tradeTimestamp: Notierungszeitpunkt; Die Angabe erfolgt in Form eines POSIX-Zeitstempels.
                        tradeTimestamp=tradeTimestamp,

                        -- Number price: Aktueller Preis oder Kurs
                        price=marketPrice,

                        -- String currencyOfPrice: Von der Kontowährung abweichende Währung des Preises.
                        -- Number purchasePrice: Kaufpreis oder Kaufkurs
                        purchasePrice=v["COST_BASIS"]["amount"],

                      -- String currencyOfPurchasePrice: Von der Kontowährung abweichende Währung des Kaufpreises.

                      }
                      table.insert(securities,security)
                    end
                  end) --pcall
                  bugReport(status,err,v)
                end
              end)--pcall
              bugReport(status,err,v)
            end
          end) --pcall
          bugReport(status,err,v)
        end
      end) --pcall
      bugReport(status,err,v)
    end
  end) --pcall
  bugReport(status,err,v)
  return {securities=securities}
end

function bugReport(status,err,v)
  if not status and reportOnce then
    reportOnce=false
    print (string.rep('#',25).." 8< please report this bug = '"..err.."' >8 "..string.rep('#',25))
    tprint(v)
    print (string.rep('#',25).." 8< please report this bug version="..Version.." >8 "..string.rep('#',25))
  end
end

function EndSession ()
  -- Logout.
  connectWithCSRF("GET","services/participant/logout")
end



