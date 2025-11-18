# UART Connection Settings
$global:UARTConnection = [PSCustomObject]@{
	Port = $null;
	BaudRate = 9600;
	SerialPort = $null;
};

# OBS Connection Settings
$global:OBSConnection = [PSCustomObject]@{
	WebSocketURL = "ws://localhost:4455";
	SourceName = "PSU Voltage & Current";
	WebSocket = $null;
}

# MODBUS Constants
$MODBUS = [PSCustomObject]@{
	Function = [PSCustomObject]@{ Read = 0x03; Write=0x06 };
	Register = [PSCustomObject]@{
		ReadCurrent          = [UInt16]0x0000;
		ReadVoltage          = [UInt16]0x0020;
		SetCurrentCorrection = [UInt16]0x0040;
		SetVoltageCorrection = [UInt16]0x0060;
	}
}

# Auxiliary functions

# Calculate CRC-16 for MODBUS commands
function Get-CRC16Modbus([Byte[]]$Data) {
	$crc = 0xFFFF;  # Initial CRC value.

	foreach ($byte in $Data) {
		$crc = $crc -bxor $byte
		for ($i = 0; $i -lt 8; $i++) {
			if ($crc -band 0x0001) {
				$crc = ($crc -shr 1) -bxor 0xA001;
				continue;
			}
			$crc = $crc -shr 1;
		}
	}

	# Convert to little-endian format (low byte first, high byte second).
	return [Byte[]](($crc -band 0xFF), (($crc -shr 8) -band 0xFF));
}

# Create a new MODBUS command with the CRC
function New-ModbusCommand (
	[Byte] $Address,
	[Byte] $Function,
	[UInt16] $Register,
	[UInt16] $ReadNumber
) {
	$data = @(
		$Address,
		$Function,
		(($Register -shr 8) -band 0xFF),
		($Register -band 0xFF), 
		(($ReadNumber -shr 8) -band 0xFF),
		($ReadNumber -band 0xFF)
	);
	#Write-Host ([BitConverter]::ToString($data));
	$crc = Get-CRC16Modbus $data;
	return [Byte[]]($data + $crc);
}

# Invoke a MODBUS command and wait for the result
function Invoke-ModbusCommand (
	[Byte] $Address,
	[Byte] $Function,
	[UInt16] $Register,
	[UInt16] $ReadNumber
) {
	if (-not $UARTConnection.SerialPort.IsOpen) { return [Byte[]]@(); }
	$command = New-ModbusCommand -Address 0x01 -Function $MODBUS.Function.Read -Register $Register -ReadNumber $ReadNumber;
	#Write-Host ([BitConverter]::ToString($command));
	$UARTConnection.SerialPort.Write([Byte[]]$command, 0, $command.Length);
	Start-Sleep -Milliseconds 100;
	$buffer = [Byte[]]::new(32);
	$bytesRead = $UARTConnection.SerialPort.Read($buffer, 0, $buffer.Length);
	if ($bytesRead -eq 0) { return [Byte[]]@(); }
	[Array]::Resize([ref]$buffer, $bytesRead);
	return $buffer;
}

# Send a WebSocket message to OBS and wait for the response
function Send-WebSocketMessage($Message) {
	$jsonMessage = $Message | ConvertTo-Json -Depth 10 -Compress;
	#Write-Host "Sending Message: $jsonMessage";
	$OBSConnection.WebSocket.SendAsync([System.ArraySegment[Byte]][System.Text.Encoding]::UTF8.GetBytes($jsonMessage), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait();

	# Read response
	$buffer = New-Object byte[] 4096;
	$receiveResult = $OBSConnection.WebSocket.ReceiveAsync([System.ArraySegment[byte]]$buffer, [System.Threading.CancellationToken]::None).Result;
	$responseJson = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $receiveResult.Count) | ConvertFrom-Json;
	#Write-Host "Response from OBS: $responseJson" -ForegroundColor Cyan;

	return $responseJson;
}

# Connect to the OBS WebSocket
function Connect-OBS() {
	Write-Host "Connecting to OBS..." -NoNewLine -ForegroundColor White;
	while ($true) {
		try {
			# Open WebSocket Connection
			$OBSConnection.WebSocket = New-Object System.Net.WebSockets.ClientWebSocket;
			#$OBSConnection.WebSocket.Options.RemoteCertificateValidationCallback = {$true};
			$OBSConnection.WebSocket.ConnectAsync((New-Object System.Uri $OBSConnection.WebSocketURL), [System.Threading.CancellationToken]::None).Wait();
			# Receive OBS Hello (`op:0`)
			$buffer = New-Object byte[] 4096;
			$receiveResult = $OBSConnection.WebSocket.ReceiveAsync([System.ArraySegment[byte]]$buffer, [System.Threading.CancellationToken]::None).Result;
			$helloResponse = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $receiveResult.Count) | ConvertFrom-Json;
			Write-Debug "Received Hello from OBS: $helloResponse";
			# Send Request RPC Version (`op:1`)
			Send-WebSocketMessage -Message @{ op = 1; d = @{ rpcVersion = 1 } } | Out-Null;
			# Send Identify (`op:2`)
			# $identifyMessage = @{
			#     op = 2
			#     d  = @{
			#         rpcVersion = 1
			#         eventSubscriptions = 0  # No event subscriptions
			#     }
			# }
			# Send-WebSocketMessage $identifyMessage
			Write-Host " OK" -ForegroundColor Green;
			break;
		}
		catch {
			if ($null -ne $OBSConnection.WebSocket) { $OBSConnection.WebSocket.Dispose(); }
			Start-Sleep -Seconds 1;
			Write-Host "." -NoNewLine -ForegroundColor White;
			continue;
		}
	}
}

function Connect-PSU() {
	Write-Host "Connecting to PSU UART Port ($($UARTConnection.Port))..." -NoNewLine -ForegroundColor White;
	while ($true) {
		try {
			# Open Serial Port
			$UARTConnection.SerialPort = New-Object System.IO.Ports.SerialPort $UARTConnection.Port, $UARTConnection.BaudRate, None, 8, one;
			#$UARTConnection.SerialPort.Encoding = $encoding;
			$UARTConnection.SerialPort.Open();
			Write-Host " OK" -ForegroundColor Green;
			break;
		}
		catch {
			if ($null -ne $UARTConnection.SerialPort) {
				$UARTConnection.SerialPort.Close();
				$UARTConnection.SerialPort.Dispose();
			}
			Start-Sleep -Seconds 1;
			Write-Host "." -NoNewLine -ForegroundColor White;
			continue;
		}
	}
}

function Get-PSUPort {
	$psuBT = Get-PnpDevice | Where-Object { $_.Class -eq "Bluetooth" -and $_.FriendlyName -eq "Bench Power Supply" -and $_.InstanceId -ilike "BTHENUM*" -and $_.Status -eq "OK" };
	$deviceId = ($psuBT.InstanceId -split "_")[2];
	$psuPort = Get-WmiObject -query "select DeviceID,PNPDeviceID from Win32_SerialPort" | Where-Object { $_.PNPDeviceID -ilike "*$deviceId*" };
	$psuPort.DeviceID;
}

function New-OBSWSUpdateTextCommand([String] $Source, [String] $Text) {
	return @{
		op = 6
		d  = @{
			requestType = "SetInputSettings"
			requestId   = "updateText"
			requestData = @{
				inputName = $Source
				inputSettings = @{
					text = $Text;
				}
			}
		}
	};
}

function Invoke-OBSWSUpdateText([String] $Source, [String] $Text) {
	$command = New-OBSWSUpdateTextCommand -Source $Source -Text $Text;
	try {
		Send-WebSocketMessage $command | Out-Null;
	}
	catch {
		Write-Host "E" -ForegroundColor DarkRed -NoNewline;
		$OBSConnection.WebSocket.Dispose();
		Connect-OBS;
	}
}

function Get-Voltage {
	try {
		$result = Invoke-ModbusCommand -Address 0x01 -Function $MODBUS.Function.Read -Register $MODBUS.Register.ReadVoltage -ReadNumber 0x0002;
		if ($result.Length -ge 5) {
			return (([UInt16]$result[3] -shl 8) + $result[4]) / 100.0;
		}
		return 0.0;
	}
	catch {
		Write-Host "E" -ForegroundColor DarkRed -NoNewline;
		$UARTConnection.SerialPort.Dispose();
		Connect-PSU;
	}
}

function Get-Current {
	try {
		$result = Invoke-ModbusCommand -Address 0x01 -Function $MODBUS.Function.Read -Register $MODBUS.Register.ReadCurrent -ReadNumber 0x0002;
		if ($result.Length -ge 9) {
			return (([UInt16]$result[5] -shl 8) + $result[6]) / 1000.0;
		}
		return 0.0;
	}
	catch {
		Write-Host "E" -ForegroundColor DarkRed -NoNewline;
		$UARTConnection.SerialPort.Dispose();
		Connect-PSU;
	}
}

# Main Start
$UARTConnection.Port = Get-PSUPort;
if (-not $UARTConnection.Port -ilike "COM*") {
	Write-Host "Cannot find the PSU COM port!" -ForegroundColor Red;
	Read-Host;
	exit;
}

Write-Host "Starting PSU Streaming" -ForegroundColor Yellow;
Write-Host "[ $($OBSConnection.WebSocketURL) / $($UARTConnection.Port) / $($UARTConnection.BaudRate) / $($OBSConnection.SourceName) ]" -ForegroundColor Cyan;

# Setup
Connect-OBS;
Connect-PSU;

Write-Host "Press Q to quit" -ForegroundColor Magenta;

# Update loop
$loopCount = 0;
try {
	# # # Setup current correction
	# $milliAmps = [UInt16]6312;
	# $result = Invoke-ModbusCommand -SerialPort $serial -Address 0xFF -Function $MODBUS.Function.Write -Register $MODBUS.Register.SetCurrentCorrection -ReadNumber $milliAmps;

	# # Setup voltage correction
	# $milliAmps = 0x03E8;
	# $result = Invoke-ModbusCommand -SerialPort $serial -Address 0x01 -Function $MODBUS.Function.Write -Register $MODBUS.Register.SetVoltageCorrection -ReadNumber $milliAmps;

	# # Restore factory settings
	#Invoke-ModbusCommand -SerialPort $serial -Address 0xFF -Function $MODBUS.Function.Write -Register 0x00FB -ReadNumber 0xEDE5;
	while ($true) {
		# Get Voltage
		$voltage = Get-Voltage;
		$current = Get-Current;
		# Send voltage and current values to OBS
		Invoke-OBSWSUpdateText -Source $OBSConnection.SourceName -Text "$voltage V`r`n$current A`r`n$($voltage * $current) W";
		Write-Debug "Voltage: $voltage V | Current: $current A";
		if ([Console]::KeyAvailable) { if ([Console]::ReadKey($true).Key -eq [ConsoleKey]::Q) { Write-Host ""; break; } }
		if (($loopCount % 10) -eq 0) {
			Write-Host "." -NoNewline -ForegroundColor White;
			$loopCount = 0;
		}
		$loopCount++;
	}
}
finally {
	$UARTConnection.SerialPort.Close();
	$UARTConnection.SerialPort.Dispose();
	$OBSConnection.WebSocket.Dispose();
}
