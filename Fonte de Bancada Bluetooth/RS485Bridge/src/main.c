#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <string.h>

#include "esp_log.h"
#include "nvs_flash.h"

#include "driver/gpio.h"
#include "driver/uart.h"

#include "esp_bt.h"
#include "esp_bt_device.h"
#include "esp_bt_main.h"
#include "esp_gap_bt_api.h"
#include "esp_spp_api.h"

// Pin configuration (ESP32 DevKit v1)
#define UART_NUM UART_NUM_2
#define UART_TX_PIN GPIO_NUM_17  // ESP32 TX2 -> MAX3485 DI
#define UART_RX_PIN GPIO_NUM_16  // MAX3485 RO -> ESP32 RX2
#define UART_RTS_PIN GPIO_NUM_22 // drives MAX3485 DE (/RE tied to DE)
#define UART_BAUD 9600

static const char *TAG = "RS485_SPP";
static uint32_t g_spp_handle = 0;

// SPP callback
static void spp_cb(esp_spp_cb_event_t event, esp_spp_cb_param_t *param) {
	switch (event) {
		case ESP_SPP_INIT_EVT:
			// Start SPP server (acceptor)
			if (param->init.status == ESP_SPP_SUCCESS) {
				ESP_LOGI(TAG, "SPP init done, service starting...");
				esp_spp_start_srv(ESP_SPP_SEC_AUTHENTICATE, ESP_SPP_ROLE_SLAVE, 0, "SPP_SERVER_RS485");
			}
			else
				ESP_LOGE(TAG, "ESP_SPP_INIT_EVT status: %d", param->init.status);
			break;
		case ESP_SPP_START_EVT:
			if (param->start.status == ESP_SPP_SUCCESS) {
				esp_bt_gap_set_device_name("Bench Power Supply");
				esp_bt_gap_set_scan_mode(ESP_BT_CONNECTABLE, ESP_BT_GENERAL_DISCOVERABLE);
			}
			else
				ESP_LOGE(TAG, "ESP_SPP_START_EVT status: %d", param->start.status);
			break;
		case ESP_SPP_SRV_OPEN_EVT:
			g_spp_handle = param->srv_open.handle;
			ESP_LOGI(TAG, "SPP connected (handle=%lu)", g_spp_handle);
			break;
		case ESP_SPP_CLOSE_EVT:
			ESP_LOGI(TAG, "SPP disconnected");
			g_spp_handle = 0;
			break;
		case ESP_SPP_DATA_IND_EVT:
			// Data from BT -> push to RS485
			if (param->data_ind.len <= 0) break;
			uart_write_bytes(UART_NUM, (const char *)param->data_ind.data, param->data_ind.len);
			break;
		default:
			break;
	}
}

// GAP callback: pairing & visibility
static void gap_cb(esp_bt_gap_cb_event_t event, esp_bt_gap_cb_param_t *param) {
	switch (event) {
		case ESP_BT_GAP_AUTH_CMPL_EVT:
			ESP_LOGI("RS485_SPP", "auth %s", param->auth_cmpl.stat == ESP_BT_STATUS_SUCCESS ? "ok" : "fail");
			break;
		case ESP_BT_GAP_PIN_REQ_EVT:
			esp_bt_pin_code_t pin = {'1', '2', '3', '4'}; // legacy PIN fallback
			esp_bt_gap_pin_reply(param->pin_req.bda, true, 4, pin);
			break;
		case ESP_BT_GAP_CFM_REQ_EVT:
			ESP_LOGI(TAG, "ESP_BT_GAP_CFM_REQ_EVT Please compare the numeric value: %06" PRIu32, param->cfm_req.num_val);
			esp_bt_gap_ssp_confirm_reply(param->cfm_req.bda, true);
			break;
		default:
			break;
	}
}

// Task UART -> SPP
static void uart_to_spp_task(void *arg) {
	uint8_t buf[256];
	while (true) {
		int n = uart_read_bytes(UART_NUM, buf, sizeof(buf), pdMS_TO_TICKS(50));
		if (n <= 0 || !g_spp_handle) continue;
		esp_spp_write(g_spp_handle, n, buf);
	}
}

void app_main(void) {
	// NVS is required by BT stack
	esp_err_t ret = nvs_flash_init();
	if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
		ESP_ERROR_CHECK(nvs_flash_erase());
		ret = nvs_flash_init();
	}
	ESP_ERROR_CHECK(ret);
	// Configure UART2 as RS485 half-duplex (driver will toggle RTS->DE during TX)
	uart_config_t cfg = {
		.baud_rate = UART_BAUD,
		.data_bits = UART_DATA_8_BITS,
		.parity = UART_PARITY_DISABLE, // change if your bus uses parity
		.stop_bits = UART_STOP_BITS_1, // change to 2 if needed
		.flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
		.source_clk = UART_SCLK_APB,
	};
	ESP_ERROR_CHECK(uart_param_config(UART_NUM, &cfg));
	ESP_ERROR_CHECK(uart_set_pin(UART_NUM, UART_TX_PIN, UART_RX_PIN, UART_RTS_PIN, UART_PIN_NO_CHANGE));
	ESP_ERROR_CHECK(uart_driver_install(UART_NUM, 2048, 0, 0, NULL, 0));
	ESP_ERROR_CHECK(uart_set_mode(UART_NUM, UART_MODE_RS485_HALF_DUPLEX));

	// Classic Bluetooth SPP init (Bluedroid)
	// Free BLE memory (only if BLE is enabled in Kconfig)
#if CONFIG_BT_BLE_ENABLED
	esp_bt_controller_mem_release(ESP_BT_MODE_BLE);
#endif

	esp_bt_controller_config_t bt_cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
	if ((ret = esp_bt_controller_init(&bt_cfg)) != ESP_OK) {
		ESP_LOGE(TAG, "%s initialize controller failed: %s", __func__, esp_err_to_name(ret));
		return;
	}

	if ((ret = esp_bt_controller_enable(ESP_BT_MODE_CLASSIC_BT)) != ESP_OK) {
		ESP_LOGE(TAG, "%s enable controller failed: %s", __func__, esp_err_to_name(ret));
		return;
	}

	if ((ret = esp_bluedroid_init()) != ESP_OK) {
		ESP_LOGE(TAG, "%s initialize bluedroid failed: %s", __func__, esp_err_to_name(ret));
		return;
	}

	if ((ret = esp_bluedroid_enable()) != ESP_OK) {
		ESP_LOGE(TAG, "%s enable bluedroid failed: %s", __func__, esp_err_to_name(ret));
		return;
	}

	if ((ret = esp_bt_gap_register_callback(gap_cb)) != ESP_OK) {
		ESP_LOGE(TAG, "%s gap register failed: %s", __func__, esp_err_to_name(ret));
		return;
	}

	if ((ret = esp_spp_register_callback(spp_cb)) != ESP_OK) {
		ESP_LOGE(TAG, "%s SPP register failed: %s", __func__, esp_err_to_name(ret));
		return;
	}

	// Make device discoverable & connectable; set IO capabilities
	// uint8_t iocap = ESP_BT_IO_CAP_NONE; // Just Works
	// ESP_ERROR_CHECK(esp_bt_gap_set_security_param(ESP_BT_SP_IOCAP_MODE, &iocap, sizeof(iocap)));
	// ESP_ERROR_CHECK(esp_bt_gap_set_scan_mode(ESP_BT_CONNECTABLE, ESP_BT_GENERAL_DISCOVERABLE));

	const esp_spp_cfg_t spp_cfg = {.mode = ESP_SPP_MODE_CB, .enable_l2cap_ertm = true};
	if ((ret = esp_spp_enhanced_init(&spp_cfg)) != ESP_OK) {
		ESP_LOGE(TAG, "%s SPP init failed: %s", __func__, esp_err_to_name(ret));
		return;
	}

	// Set default parameters for Secure Simple Pairing
	esp_bt_sp_param_t param_type = ESP_BT_SP_IOCAP_MODE;
	esp_bt_io_cap_t iocap = ESP_BT_IO_CAP_IO;
	esp_bt_gap_set_security_param(param_type, &iocap, sizeof(uint8_t));

	// Set default parameters for Legacy Pairing
	// Use variable pin, input pin code when pairing
	esp_bt_pin_type_t pin_type = ESP_BT_PIN_TYPE_VARIABLE;
	esp_bt_pin_code_t pin_code;
	esp_bt_gap_set_pin(pin_type, 0, pin_code);

	// Pump UART -> SPP
	xTaskCreate(uart_to_spp_task, "uart_to_spp", 4096, NULL, 10, NULL);
}
